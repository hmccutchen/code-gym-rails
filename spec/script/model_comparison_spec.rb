require "rails_helper"
require Rails.root.join("script/model_comparison")

RSpec.describe ModelComparison do
  let(:user) { User.create!(email: "compare@example.com", name: "Compare") }
  let(:out) { StringIO.new }
  let(:posted) { [] }
  let(:comparison) { described_class.new(api_key: "sk-ant-runner", out: out) }

  # Answers every request the way FakeService would, in Anthropic's response
  # shape, so each mode's real prompt building and parsing runs end to end.
  before do
    requests = posted
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          body   = JSON.parse(env.body)
          system = body["system"].is_a?(Array) ? body["system"].first["text"] : body["system"]
          requests << body
          text = FakeService.new("unused").send(:call, system: system, prompt: body["messages"].last["content"])[:text]
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
    expect(out.string).not_to include(ProblemSetIngest::ANSWER_KEY_FIELD)
  end
end
