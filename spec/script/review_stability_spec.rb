require "rails_helper"
require Rails.root.join("script/model_comparison")

RSpec.describe ReviewStability do
  let(:user) { User.create!(email: "stability@example.com", name: "Stability") }
  let(:out) { StringIO.new }
  let(:posted) { [] }
  # Ratings for successive grades; :bad_key answers 401 and any grade past the queue is "solid".
  let(:replies) { [] }
  let(:export_path) { Rails.root.join("tmp/review_stability_spec_#{Process.pid}.json") }
  let(:comparison) { ModelComparison.new(api_key: "sk-ant-runner", out: out) }

  before do
    requests = posted
    queue    = replies
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          requests << JSON.parse(env.body)
          reply = queue.shift || "solid"
          next [ 401, {}, { "error" => { "type" => "authentication_error" } }.to_json ] if reply == :bad_key

          text = FakeService::REVIEW_SECTION.merge("rating" => reply).to_json
          [ 200, {}, { "content" => [ { "type" => "text", "text" => text } ],
                       "usage" => { "input_tokens" => 70, "output_tokens" => 30 } }.to_json ]
        end
      end
    end
    allow_any_instance_of(ClaudeService).to receive(:build_connection).and_return(connection)
  end

  after { FileUtils.rm_f(export_path) }

  def export_days(sections_by_date, review_provider: "anthropic")
    sections_by_date.each do |date, sections|
      exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                       problem_set: sections.index_with { { "question" => "q", "snippet" => "s", "pitched_at" => "senior" } })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current, review_provider: review_provider,
                            answers: sections.index_with { "An answer." }, section_ratings: sections.index_with { "right_level" },
                            ai_review: sections.index_with { { "rating" => "solid", "rubric" => ReviewedSectionResults::RUBRIC_VERSION } })
    end
    File.write(export_path, JSON.generate(ReviewBaselineExport.new(user_id: user.id).call))
  end

  it "plans without a provider call: sections by kind, the call count and an estimated cost" do
    export_days({ Date.new(2026, 10, 20) => %w[code_review challenge] })

    comparison.review_stability(export_path, runs: 5)

    expect(posted).to be_empty
    expect(out.string).to include("no provider call made", "sections: 2 · challenge 1, code_review 1", "calls: 10")
    expect(out.string).to match(/cache read .* · \$\d+\.\d{2}\nworst case, .* \$\d+\.\d{2}/)
  end

  it "grades every section the asked number of times on the production review route and reports how the ratings moved" do
    export_days({ Date.new(2026, 10, 20) => %w[code_review challenge] })
    replies.concat(%w[solid developing solid] + %w[strong strong beginner])

    comparison.review_stability(export_path, runs: 3, run: true)

    expect(posted.size).to eq(6)
    expect(posted.map { |body| body["model"] }.uniq).to eq([ ClaudeService::DEFAULT_ROUTE[:model] ])
    expect(out.string).to include("2026-10-20 code_review (senior): stored solid · runs solid developing solid")
    expect(out.string).to include("2026-10-20 challenge (senior): stored solid · runs strong strong beginner")
    expect(out.string).to include("code_review: 1 sections · changed between runs 1/1 · spread 0:0 1:1 2:0 3:0 · " \
                                  "moved more than one level 0/1 · failed or unusable grades 0")
    expect(out.string).to include("all kinds: 2 sections · changed between runs 2/2 · spread 0:0 1:1 2:0 3:1 · " \
                                  "moved more than one level 1/2")
  end

  it "writes nothing to the database while grading" do
    export_days({ Date.new(2026, 10, 20) => %w[code_review] })
    counts = -> { [ ApiUsage.count, DailyResponse.count, DailyExercise.count, User.count ] }

    expect { comparison.review_stability(export_path, runs: 2, run: true) }.not_to change(&counts)
    expect(DailyResponse.sole.ai_review["code_review"]).to eq("rating" => "solid", "rubric" => ReviewedSectionResults::RUBRIC_VERSION)
  end

  it "stops at a failure no later call could recover from and reports the sections it finished" do
    export_days({ Date.new(2026, 10, 19) => %w[code_review], Date.new(2026, 10, 20) => %w[challenge] })
    replies.concat(%w[solid solid] + [ :bad_key ])

    comparison.review_stability(export_path, runs: 2, run: true)

    expect(posted.size).to eq(3)
    expect(out.string).to include("stopped early, after 1 of 2 sections:")
    expect(out.string).to include("all kinds: 1 sections")
  end

  it "reports counts, never a percentage" do
    export_days({ Date.new(2026, 10, 20) => %w[code_review] })

    comparison.review_stability(export_path, runs: 3, run: true)

    expect(out.string).not_to include("%")
  end

  it "keeps a rating outside the four levels out of the report and counts it as unusable" do
    export_days({ Date.new(2026, 10, 20) => %w[code_review] })
    replies.concat([ "solid", "SENTINEL-PROSE the answer said includes(:customer)" ])

    comparison.review_stability(export_path, runs: 2, run: true)

    expect(out.string).not_to include("SENTINEL-PROSE")
    expect(out.string).to include("stored solid · runs solid - · failed 1")
    expect(out.string).to include("failed or unusable grades 1")
  end

  it "counts a section with fewer than two grades as too few to compare" do
    row = described_class::Row.new(date: Date.current, section: "code_review", rung: "senior", stored_rating: "solid",
                                   stored_provider: "anthropic", ratings: [ "solid", nil ], failures: 1)

    described_class.new(out: out).print_report([ row ], runs: 2, route: { model: "m" }, regrade_provider: "anthropic", cost_line: "$0")

    expect(out.string).to include("runs solid - · failed 1")
    expect(out.string).to include("changed between runs 0/0 · spread 0:0 1:0 2:0 3:0 · moved more than one level 0/0 · " \
                                  "failed or unusable grades 1 · too few grades to compare 1")
  end

  describe "drift from the stored review" do
    def row(section, stored_rating, stored_provider, ratings)
      described_class::Row.new(date: Date.current, section: section, rung: "senior", stored_rating: stored_rating,
                               stored_provider: stored_provider, ratings: ratings, failures: 0)
    end

    def report(rows)
      described_class.new(out: out).print_report(rows, runs: 2, route: { model: "m" }, regrade_provider: "anthropic", cost_line: "$0")
      out.string
    end

    it "says the recorded provider is the one that wrote the day's last review attempt" do
      printed = report([ row("code_review", "solid", "anthropic", %w[solid solid]) ])

      expect(printed).to include("a day records the provider of its last review attempt, " \
                                 "so a section graded in an earlier attempt may come from another")
    end

    it "labels the stored-rating comparison as drift, apart from the stability lines" do
      printed = report([ row("code_review", "solid", "anthropic", %w[solid developing]) ])

      expect(printed).to include("drift, not stability: regrades on anthropic matching the stored rating")
      expect(printed).to include("code_review drift, day's last recorded provider anthropic: matching 1/2\n")
      expect(printed.lines.grep(/changed between runs/)).to all(satisfy { |line| !line.include?("matching") })
    end

    it "splits drift by the stored review's provider and says when it differs from the regrade's" do
      printed = report([ row("code_review", "solid", "anthropic", %w[solid solid]),
                         row("code_review", "strong", "openai", %w[solid developing]),
                         row("code_review", "solid", nil, %w[solid solid]) ])

      expect(printed).to include("code_review drift, day's last recorded provider anthropic: matching 2/2\n")
      expect(printed).to include("code_review drift, day's last recorded provider openai: matching 0/2 · " \
                                 "not the regrade's provider (anthropic), so this also compares providers")
      expect(printed).to include("code_review drift, no recorded provider: matching 2/2 · " \
                                 "the stored review may come from a different provider than the regrade")
    end

    it "leaves a section with no stored rating out of the drift denominator and says how many" do
      printed = report([ row("challenge", "solid", "anthropic", %w[solid developing]),
                         row("challenge", nil, "anthropic", %w[solid solid]) ])

      expect(printed).to include("challenge drift, day's last recorded provider anthropic: matching 1/2\n")
      expect(printed).to include("challenge drift: 1 sections with no stored rating left out")
      expect(printed).to include("stored none · runs solid solid")
    end

    it "takes the stored provider from the export and the regrade provider from the route in a real run" do
      export_days({ Date.new(2026, 10, 20) => %w[code_review] }, review_provider: "gemini")

      comparison.review_stability(export_path, runs: 2, run: true)

      expect(out.string).to include("code_review drift, day's last recorded provider gemini: matching 2/2 · " \
                                    "not the regrade's provider (anthropic)")
    end
  end
end
