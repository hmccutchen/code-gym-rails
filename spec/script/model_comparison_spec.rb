require "rails_helper"
require Rails.root.join("script/model_comparison")

RSpec.describe ModelComparison do
  let(:user) { User.create!(email: "compare@example.com", name: "Compare") }
  let(:out) { StringIO.new }
  let(:posted) { [] }
  let(:judge_replies) { [] }
  let(:comparison) { described_class.new(api_key: "sk-ant-runner", out: out) }

  # Answers every request the way FakeService would, in Anthropic's response
  # shape, so each mode's real prompt building and parsing runs end to end.
  before do
    requests = posted
    replies  = judge_replies
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          body   = JSON.parse(env.body)
          system = body["system"].is_a?(Array) ? body["system"].first["text"] : body["system"]
          requests << body
          if system == AiService::REVIEW_PROSE_JUDGE_SYSTEM_PROMPT && replies.any?
            reply = replies.shift
            next [ 500, {}, "{}" ] if reply == :provider_error

            text = reply.is_a?(String) ? reply : reply.to_json
          else
            text = FakeService.new("unused").send(:call, system: system, prompt: body["messages"].last["content"])[:text]
          end
          [ 200, {}, { "content" => [ { "type" => "text", "text" => text } ],
                       "usage" => { "input_tokens" => 70, "output_tokens" => 30 } }.to_json ]
        end
      end
    end
    allow_any_instance_of(ClaudeService).to receive(:build_connection).and_return(connection)
  end

  def create_exercise(problem_set = FakeService::EXERCISE_PROBLEM_SET)
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                          language: "ruby_rails", problem_set: problem_set.deep_stringify_keys)
  end

  it "runs the duck against each candidate model and prints both, labeled" do
    exercise = create_exercise

    comparison.duck(exercise.id, section: "code_review")

    expect(posted.map { |body| body["model"] }).to eq(ModelComparison::CANDIDATES.fetch("duck").map { |route| route[:model] })
    ModelComparison::CANDIDATES.fetch("duck").each do |route|
      expect(out.string).to include("--- #{route[:model]}")
    end
    expect(out.string).to include("70 in / 30 out").and include(FakeService::DUCK_RESPONSE_TEXT)
  end

  it "bills the runner's key and writes no ApiUsage rows" do
    exercise = create_exercise

    expect { comparison.duck(exercise.id, section: "code_review") }.not_to change(ApiUsage, :count)
  end

  it "sends each generation candidate's effort, and no effort where the candidate names none" do
    comparison.generate(user.id)

    expect(posted.map { |body| body["output_config"] })
      .to eq(ModelComparison::CANDIDATES.fetch("generate").map { |route| route[:effort] && { "effort" => route[:effort] } })
  end

  it "never prints the ambiguity hunt's answer key" do
    comparison.generate(user.id)

    expect(out.string).to include("ambiguity_hunt")
    expect(out.string).not_to include(ProblemSetIngest::ANSWER_KEY_FIELD)
  end

  it "prints a malformed provider response as that model's result rather than losing both" do
    allow_any_instance_of(ClaudeService).to receive(:call).and_raise(JSON::ParserError, "unexpected token")
    exercise = create_exercise

    comparison.duck(exercise.id, section: "code_review")

    expect(out.string.scan("JSON::ParserError: unexpected token").size).to eq(2)
  end

  # Each DailyPlan.for rolls the day's shape afresh, so without a shared plan
  # the two candidates would be answering different requests.
  it "sends both generation candidates the same prompt" do
    comparison.generate(user.id)

    expect(posted.map { |body| body["messages"] }.uniq.size).to eq(1)
  end

  it "leaves DailyPlan.for as it found it" do
    comparison.generate(user.id)

    expect(DailyPlan.method(:for).source_location.first).to end_with("app/services/daily_plan.rb")
  end

  it "prints the rating, missed points and next step of each answered section's review" do
    exercise = create_exercise
    response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                     answers: { "code_review" => "The query runs once per row, so preload it." },
                                     submitted_at: Time.current)

    comparison.review(response.id)

    expect(posted.size).to eq(ModelComparison::CANDIDATES.fetch("review").size)
    expect(out.string).to include("review: code_review")
      .and include("\"rating\"").and include("\"missed\"").and include("\"next_step\"")
    expect(out.string).not_to include("\"improved_code\"")
  end

  it "says when a pseudocode section is graded without a saved translation" do
    exercise = create_exercise(FakeService::EXERCISE_PROBLEM_SET.slice("code_review", "pseudocode_to_code"))
    response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                     answers: { "pseudocode_to_code" => "for each item, keep it unless seen" },
                                     submitted_at: Time.current)

    comparison.review(response.id)

    expect(out.string).to include("review: pseudocode_to_code (no saved translation, so graded as written)")
  end

  it "translates the stored pseudocode answer with each candidate" do
    exercise = create_exercise
    response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                     answers: { "pseudocode_to_code" => "for each item, keep it unless seen" })

    comparison.translate(response.id)

    expect(posted.map { |body| body["model"] }).to eq(ModelComparison::CANDIDATES.fetch("translate").map { |route| route[:model] })
    expect(out.string).to include(FakeService::PSEUDOCODE_TRANSLATION)
  end

  it "prints a provider failure in place of that model's output rather than stopping" do
    allow_any_instance_of(ClaudeService).to receive(:call).and_raise(AiService::RateLimitError, "slow down")
    exercise = create_exercise

    comparison.duck(exercise.id, section: "code_review")

    expect(out.string.scan("AiService::RateLimitError: slow down").size).to eq(2)
  end

  it "drafts once, judges every section with each candidate, and prints a verdict block per section" do
    comparison.judge(user.id)

    expect(posted.map { |body| body["model"] }.uniq).to eq(ModelComparison::CANDIDATES.fetch("judge").map { |route| route[:model] })
    ModelComparison::CANDIDATES.fetch("judge").each { |route| expect(out.string).to include("--- #{route[:model]}") }
    expect(out.string).to include("\"code_review\"").and include("\"status\"")
  end

  it "never prints the ambiguity hunt's planted answer key while judging" do
    plan = DailyPlan.for(user, language: "ruby_rails").with(fourth: "ambiguity_hunt")
    allow(DailyPlan).to receive(:for).and_return(plan)

    comparison.judge(user.id)

    expect(out.string).to include("ambiguity_hunt")
    expect(out.string).not_to include(ProblemSetIngest::ANSWER_KEY_FIELD)
  end

  it "judge_fixtures prints a per-model detection table and never the answer key" do
    fixture_dir = Rails.root.join("spec/fixtures/judge")
    verdicts = Dir[fixture_dir.join("*.json")].to_h do |path|
      fixture = JSON.parse(File.read(path))
      verdict = fixture["expected"] == "reject" ? JudgeVerdict.new(status: :reject, principle: fixture["principle"], evidence: "quoted text", reason: "why") :
                                                   JudgeVerdict.new(status: :keep)
      [ fixture["section"], verdict ]
    end
    allow_any_instance_of(ClaudeService).to receive(:judge_section) { |_service, _user, _kind, section, **| verdicts.fetch(section) }

    comparison.judge_fixtures

    ModelComparison::CANDIDATES.fetch("judge").each { |route| expect(out.string).to include("=== judge_fixtures: #{route[:model]} ===") }
    expect(out.string).to include("detected:")
    expect(out.string).to include("unstated_prerequisite: 2/2")
    expect(out.string).not_to include(ProblemSetIngest::ANSWER_KEY_FIELD)
  end

  it "judge_fixtures prints a provider failure as that fixture's row and finishes every table" do
    failing = JSON.parse(File.read(Rails.root.join("spec/fixtures/judge/thread_prerequisite.json")))["section"]
    allow_any_instance_of(ClaudeService).to receive(:judge_section) do |_service, _user, _kind, section, **|
      raise AiService::RateLimitError, "slow down" if section == failing

      JudgeVerdict.new(status: :keep)
    end

    comparison.judge_fixtures

    ModelComparison::CANDIDATES.fetch("judge").each { |route| expect(out.string).to include("=== judge_fixtures: #{route[:model]} ===") }
    expect(out.string.scan(/^thread_prerequisite: .*got=error .*AiService::RateLimitError: slow down/).size)
      .to eq(ModelComparison::CANDIDATES.fetch("judge").size)
    expect(out.string).to include("valid: 10/11")
  end

  it "judge_fixtures prints each edit's issues with the text they quote" do
    allow_any_instance_of(ClaudeService).to receive(:judge_section).and_return(
      JudgeVerdict.new(status: :edit, issues: [ { type: "padding", evidence: "Once upon a time" } ],
                       fields: { "question" => "Shorter?" })
    )

    comparison.judge_fixtures

    expect(out.string).to include("issues=padding: \"Once upon a time\"")
  end

  describe "review prose measurement" do
    let(:section_review) do
      { "rating" => "solid", "correct" => [ "Spotted it." ],
        "missed" => [ "One query per row.", "Each row runs its own query." ],
        "better_questions" => [], "next_step" => "Read about includes." }
    end
    let(:edit_reply) do
      { "status" => "edit", "issues" => [ { "type" => "verbosity", "evidence" => "Each row runs its own query." } ],
        "fields" => { "missed" => [ { "from" => [ 0, 1 ], "text" => "One query per row." } ] } }
    end

    def judge_requests = posted.select { |body| body["system"] == AiService::REVIEW_PROSE_JUDGE_SYSTEM_PROMPT }

    def store_reviews(sections)
      DailyResponse.create!(user: user, daily_exercise: create_exercise, date: Date.current, submitted_at: Time.current,
                            answers: { "code_review" => "x" * 20 }, ai_review: sections.index_with { section_review })
    end

    it "judges each stored review with each candidate, printing rewrites beside their sources and a summary per model" do
      store_reviews(%w[code_review pattern challenge architecture])
      # First candidate: edit, keep, a reply that is not a verdict, a provider failure. Second: all keep.
      judge_replies.push(edit_reply, { "status" => "keep" }, "not json at all", :provider_error)

      comparison.review_prose(user.id)

      sonnet, haiku = ModelComparison::CANDIDATES.fetch("review_prose").map { |route| route[:model] }
      expect(judge_requests.size).to eq(8)
      expect(out.string).to include("=== review_prose: user #{user.id} · #{sonnet} ===")
        .and include("=== review_prose: user #{user.id} · #{haiku} ===")
        .and include("[0, 1] now: One query per row.")
        .and include("was[1]: Each row runs its own query.")
        .and include("issues: verbosity: \"Each row runs its own query.\"")
        .and include("AiService::InvalidResponseError")
        .and include("AiService::Error")
      expect(out.string).to match(%r{edits: 1/2 \(plain_language_violation 0/2, verbosity 1/2\) · merges: 1 · invalid: 1/4 · provider errors: 1/4 · \d+ms})
      expect(out.string).to match(%r{edits: 0/4 \(plain_language_violation 0/4, verbosity 0/4\) · merges: 0 · invalid: 0/4 · provider errors: 0/4})
      expect(out.string).to include("$")
    end

    it "reads each response's exercise without a query per response" do
      3.times do |i|
        exercise = DailyExercise.create!(user: user, date: Date.current - i - 1, generated_at: Time.current, language: "ruby_rails",
                                         problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_stringify_keys)
        DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - i - 1, submitted_at: Time.current,
                              answers: { "code_review" => "x" * 20 }, ai_review: { "code_review" => section_review })
      end

      exercise_queries = 0
      counter = ->(*, payload) { exercise_queries += 1 if payload[:sql].include?(%("daily_exercises")) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { comparison.review_prose(user.id) }

      expect(exercise_queries).to eq(1)
    end

    it "refuses a limit that is not a positive integer before any call" do
      expect { comparison.review_prose(user.id, limit: 0) }.to raise_error(ArgumentError)
      expect { comparison.review_prose(user.id, limit: "5x") }.to raise_error(ArgumentError)
      expect(posted).to be_empty
    end

    it "judges a review the live judge already edited from the grader's original" do
      DailyResponse.create!(user: user, daily_exercise: create_exercise, date: Date.current, submitted_at: Time.current,
                            answers: { "code_review" => "x" * 20 },
                            ai_review: { "code_review" => section_review.merge("missed" => [ "Rewritten." ],
                                                                               "graded_prose" => { "missed" => [ "GRADER-ORIGINAL" ] }) })

      comparison.review_prose(user.id)

      prompt = judge_requests.first["messages"].last["content"]
      expect(prompt).to include("GRADER-ORIGINAL")
      expect(prompt).not_to include("Rewritten.")
    end

    it "runs every fixture with each candidate, with must-survive claims and a matched-status count" do
      comparison.review_prose_fixtures

      fixtures = Dir[ModelComparison::REVIEW_PROSE_FIXTURE_DIR.join("*.json")].size
      expect(judge_requests.size).to eq(fixtures * ModelComparison::CANDIDATES.fetch("review_prose").size)
      ModelComparison::CANDIDATES.fetch("review_prose").each do |route|
        expect(out.string).to include("=== review_prose_fixtures: #{route[:model]} ===")
      end
      expect(out.string).to include("must survive:").and match(%r{matched expected status: \d+/#{fixtures}})
    end

    it "every fixture states its expected status and must-survive claims" do
      Dir[ModelComparison::REVIEW_PROSE_FIXTURE_DIR.join("*.json")].each do |path|
        fixture = JSON.parse(File.read(path))
        expect(%w[keep edit]).to include(fixture["expected"]), path
        expect(fixture["must_survive"]).to be_an(Array), path
        expect(ExerciseSection.keys).to include(fixture["kind"]), path
      end
    end

    context "with the prose judge switched on" do
      around do |example|
        original = ENV["REVIEW_PROSE_JUDGE"]
        ENV["REVIEW_PROSE_JUDGE"] = "1"
        example.run
      ensure
        ENV["REVIEW_PROSE_JUDGE"] = original
      end

      it "review grades each answered section once per candidate and never judges, Opus candidate included" do
        response = DailyResponse.create!(user: user, daily_exercise: create_exercise, date: Date.current,
                                         answers: { "code_review" => "The query runs once per row, so preload it." },
                                         submitted_at: Time.current)

        expect { comparison.review(response.id) }.not_to raise_error
        expect(posted.size).to eq(ModelComparison::CANDIDATES.fetch("review").size)
        expect(judge_requests).to be_empty
      end
    end
  end
end
