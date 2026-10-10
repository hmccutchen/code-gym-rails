require "rails_helper"
require Rails.root.join("script/model_comparison")

RSpec.describe ModelComparison do
  let(:user) { User.create!(email: "compare@example.com", name: "Compare") }
  let(:out) { StringIO.new }
  let(:posted) { [] }
  let(:judge_replies) { [] }
  # Output tokens for successive judge calls; any call past the queue reports 30.
  let(:judge_output_tokens) { [] }
  let(:comparison) { described_class.new(api_key: "sk-ant-runner", out: out) }

  # Answers in Anthropic's response shape so each mode's real prompt building and parsing runs end to end.
  before do
    requests = posted
    replies  = judge_replies
    judge_tokens = judge_output_tokens
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          body   = JSON.parse(env.body)
          system = body["system"].is_a?(Array) ? body["system"].first["text"] : body["system"]
          requests << body
          output_tokens = system == AiService::REVIEW_PROSE_JUDGE_SYSTEM_PROMPT && judge_tokens.any? ? judge_tokens.shift : 30
          if system == AiService::REVIEW_PROSE_JUDGE_SYSTEM_PROMPT && replies.any?
            reply = replies.shift
            next [ 500, {}, "{}" ] if reply == :provider_error

            text = reply.is_a?(String) ? reply : reply.to_json
          else
            text = FakeService.new("unused").send(:call, system: system, prompt: body["messages"].last["content"])[:text]
          end
          [ 200, {}, { "content" => [ { "type" => "text", "text" => text } ],
                       "usage" => { "input_tokens" => 70, "output_tokens" => output_tokens } }.to_json ]
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

  it "never prints any kind's answer key" do
    allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: :challenge, fourth: :ambiguity_hunt)
    comparison.generate(user.id)

    expect(out.string).to include("ambiguity_hunt", "design_comparison")
    ExerciseSection.all_answer_key_fields.each { |field| expect(out.string).not_to include(field) }
    expect(out.string).not_to include(*FakeService::EXERCISE_PROBLEM_SET.dig("design_comparison", "answer_key").values)
  end

  it "prints a malformed provider response as that model's result rather than losing both" do
    allow_any_instance_of(ClaudeService).to receive(:call).and_raise(JSON::ParserError, "unexpected token")
    exercise = create_exercise

    comparison.duck(exercise.id, section: "code_review")

    expect(out.string.scan("JSON::ParserError: unexpected token").size).to eq(2)
  end

  it "sends both generation candidates the same prompt from one shared plan" do
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
    ExerciseSection.all_answer_key_fields.each { |field| expect(out.string).not_to include(field) }
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
    ExerciseSection.all_answer_key_fields.each { |field| expect(out.string).not_to include(field) }
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
    fixture_count = Dir[Rails.root.join("spec/fixtures/judge/*.json")].size
    expect(out.string).to include("valid: #{fixture_count - 1}/#{fixture_count}")
  end

  def keep_verdict(kind, solve: "b")
    JudgeVerdict.new(status: :keep, solve: (solve if kind.judge_solve_options))
  end

  it "judge_fixtures counts an edit of a keep fixture as not kept, and accepts it for keep_or_edit" do
    allow_any_instance_of(ClaudeService).to receive(:judge_section) do |_service, _user, kind, _section, **|
      JudgeVerdict.new(status: :edit, issues: [ { type: "padding", evidence: "x" } ], fields: { "question" => "q" },
                       solve: (kind.judge_solve_options && "a"))
    end

    comparison.judge_fixtures

    keeps = Dir[Rails.root.join("spec/fixtures/judge/*.json")].count { |path| JSON.parse(File.read(path))["expected"] == "keep" }
    expect(keeps).to be >= 2
    expect(out.string).to match(/^design_comparison_junior_valid: expected=keep got=edit classification=edited/)
    expect(out.string).to match(/^design_comparison_principal_tradeoff: expected=keep_or_edit got=edit classification=ok/)
    expect(out.string).to include("kept unedited where keep was expected: 0/#{keeps}")
  end

  it "judge_fixtures reports blind-solve agreement per rung and concept without printing a solve or a key" do
    expected = Dir[Rails.root.join("spec/fixtures/judge/*.json")].map { |path| JSON.parse(File.read(path)) }
                                                                 .select { |fixture| fixture.key?("expected_better") }
    allow_any_instance_of(ClaudeService).to receive(:judge_section) do |_service, _user, kind, section, **|
      fixture = expected.find { |each| each["section"] == section }
      keep_verdict(kind, solve: fixture ? fixture["expected_better"] : "a")
    end

    comparison.judge_fixtures

    with_key = expected.size
    attempted = Dir[Rails.root.join("spec/fixtures/judge/*.json")].count { |path| JSON.parse(File.read(path))["kind"] == "design_comparison" }
    expect(out.string).to include("blind solve, claude-sonnet-5-5: valid-solve agreement #{with_key}/#{with_key} · " \
                                  "matches of attempted #{with_key}/#{with_key}")
    expect(out.string).to include("  rung junior: ", "  concept n_plus_one: ")
    expect(out.string).to include("solve=match")
    expect(out.string).not_to include("better", "expected_better")
    expect(attempted).to be > with_key
  end

  it "judge mode reports each candidate's blind-solve agreement against the drafted key" do
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: nil)

    comparison.judge(user.id)

    ModelComparison::CANDIDATES.fetch("judge").each do |route|
      expect(out.string).to include("blind solve, #{route[:model]}: valid-solve agreement 1/1 · matches of attempted 1/1")
    end
    expect(out.string).to include("\"solve\": \"match\"")
    expect(out.string).not_to include("\"better\"", "answer_key")
  end

  it "judge_fixtures prints each edit's issues with the text they quote" do
    allow_any_instance_of(ClaudeService).to receive(:judge_section).and_return(
      JudgeVerdict.new(status: :edit, issues: [ { type: "padding", evidence: "Once upon a time" } ],
                       fields: { "question" => "Shorter?" })
    )

    comparison.judge_fixtures

    expect(out.string).to include("issues=padding: \"Once upon a time\"")
  end

  describe "review calibration" do
    let(:fixtures) { Dir[ModelComparison::REVIEW_CALIBRATION_FIXTURE_DIR.join("*.json")] }

    let(:answer_count) do
      fixtures.sum { |path| ModelComparison::CALIBRATION_EXPECTED.size + Array(JSON.parse(File.read(path))["extra_answers"]).size }
    end

    it "grades every fixture's answers, extra ones included, once per candidate and prints a summary" do
      comparison.review_calibration

      expect(posted.size).to eq(answer_count * ModelComparison::CANDIDATES.fetch("review_calibration").size)
      expect(out.string).to include("=== review_calibration: #{ClaudeService::DEFAULT_ROUTE[:model]} ===")
        .and match(%r{in order: \d+/#{fixtures.size} · matched expected: \d+/#{answer_count}})
        .and include("complete answers rated solid or better:").and include("cache write")
    end

    it "reports a fixture out of rank order when FakeService grades every answer solid" do
      comparison.review_calibration

      expect(out.string).to include("OUT OF ORDER").and include("in order: 0/#{fixtures.size}")
    end

    it "grades with the route production uses for reviews" do
      expect(ModelComparison::CANDIDATES.fetch("review_calibration"))
        .to eq([ ClaudeService::MODEL_FOR_PURPOSE.fetch("review_response", ClaudeService::DEFAULT_ROUTE) ])
    end

    it "prints each extra answer beside its own expected ratings, flagging FakeService's solid as a mismatch" do
      comparison.review_calibration

      expect(out.string).to match(%r{^  vague_correct_pick solid +expected beginner/developing +MISMATCH})
      expect(out.string).to match(%r{^  other_pick_sound_reason solid +expected developing +MISMATCH})
    end

    it "grades a design comparison's extra cases from the decoded answer and the key" do
      comparison.review_calibration

      prompts = posted.map { |body| body["system"].is_a?(Array) ? body["system"].first["text"] : body["system"] }
      expect(prompts.join).to include("Picked: A. Reason:\n<#{UserText::TAG}>\nThe scenario says carriers are added monthly")
      expect(prompts.join).not_to include("pick:a")
    end

    it "every extra answer carries a label, an answer and its own expected ratings" do
      extras = fixtures.flat_map { |path| Array(JSON.parse(File.read(path))["extra_answers"]) }

      expect(extras.size).to be >= 2
      extras.each do |extra|
        expect(extra.keys).to contain_exactly("label", "answer", "expected")
        expect(extra["expected"] - ConceptMastery::AI_RATING_RANK.keys).to be_empty
      end
    end

    it "every fixture names a registered kind, a stamped rung and an answer for each quality" do
      expect(fixtures.size).to be >= 5
      fixtures.each do |path|
        fixture = JSON.parse(File.read(path))
        expect(ExerciseSection.keys).to include(fixture["kind"]), path
        expect(KindDifficulty::LEVELS).to include(fixture.dig("section", "pitched_at")), path
        expect(fixture["answers"].keys).to match_array(ModelComparison::CALIBRATION_EXPECTED.keys), path
        expect(ProblemSetIngest.vocabulary_for(fixture["kind"], fixture["language"])).to include(fixture.dig("section", "concept")), path
      end
    end
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

    # Run totals cannot show single replies against the cap: [100, 1400] and [750, 750] total the same.
    it "prints each call's output tokens and names the largest reply and slowest call against their limits" do
      store_reviews(%w[code_review pattern])
      judge_output_tokens.push(100, 1400, 750, 750)

      comparison.review_prose(user.id)

      sonnet_block, haiku_block = out.string.split(/^=== review_prose: /).drop(1)
      # ai_review is jsonb, which does not keep key order, so labels are read back from the output.
      calls = sonnet_block.scan(/^(\S+ \w+): keep \d+ms · (\d+) out$/)
      expect(calls.map(&:last)).to eq(%w[100 1400])
      expect(sonnet_block).to include("largest reply: 1400 out (#{calls.last.first}) of the #{AiService::REVIEW_JUDGE_MAX_TOKENS} cap")

      first_haiku_label = haiku_block[/^(\S+ \w+): keep \d+ms · 750 out$/, 1]
      expect(haiku_block).to include("largest reply: 750 out (#{first_haiku_label}) of the #{AiService::REVIEW_JUDGE_MAX_TOKENS} cap")
      [ sonnet_block, haiku_block ].each do |block|
        expect(block).to match(/slowest: \d+ms \(\S+ \w+\) of the #{AiService::REVIEW_JUDGE_READ_TIMEOUT * 1_000}ms timeout/)
      end
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
