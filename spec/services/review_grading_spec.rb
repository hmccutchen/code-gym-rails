require "rails_helper"

RSpec.describe ReviewGrading do
  let(:user) { User.create!(email: "grading@example.com", name: "Grading") }

  def exercise_and_response
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "cr?", "snippet" => "code" },
        "pattern"     => { "title" => "P", "question" => "pat?" },
        "challenge"   => { "question" => "Implement uniq_by" }
      }
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
      submitted_at: Time.current
    )
    [ exercise, response ]
  end

  def pseudocode_day
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "cr?", "snippet" => "code" },
                     "pseudocode_to_code" => { "title" => "P2C", "problem_statement" => "merge ranges" } }
    )
    response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "pseudocode_to_code" => "a" * 20 }, submitted_at: Time.current
    )
    [ exercise, response ]
  end

  def provider(**overrides)
    ReviewGrading::Provider.new(**{
      grade: ->(*) { { "rating" => "solid" } }, judge_prose: ->(*, **) { raise "not judged here" },
      assess_difficulty: ->(*, **) { {} }, translate: ->(*, **) { "def merged; end" },
      day_context: ->(*) { "day context" }, provider_key: "fake", judges_prose: false
    }.merge(overrides))
  end

  def review(sections, exercise:, response:, providers: nil, **overrides)
    described_class.call(user: user, exercise: exercise, response: response, sections: sections, coach: "Rails",
                         providers: providers || -> { provider(**overrides) })
  end

  def drained(queue)
    Array.new(queue.size) { queue.pop }
  end

  describe ".grade_section" do
    it "grades one section by the same rules, without assessing difficulty or translating" do
      exercise, response = pseudocode_day
      calls = []
      one = provider(assess_difficulty: ->(*, **) { calls << :assess; {} },
                     translate: ->(*, **) { calls << :translate; "code" },
                     grade: ->(*) { { "rating" => "solid", "essential_gaps" => [ 9 ] } })

      section, result = described_class.grade_section(
        "pseudocode_to_code", context: "day context", user: user, exercise: exercise, response: response,
        coach: "Rails", provider: one
      )

      expect(section).to eq("pseudocode_to_code")
      expect(result[:ok]).to be(true)
      expect(result[:review]).not_to have_key("essential_gaps")
      expect(calls).to be_empty
      expect(response.reload).not_to be_translated("pseudocode_to_code")
    end
  end

  describe "the fan-out" do
    it "builds a fresh provider for each grading thread, the difficulty thread and translation" do
      exercise, response = exercise_and_response
      built = Queue.new
      sections = %w[code_review pattern challenge]

      review(sections, exercise: exercise, response: response, providers: -> { built << 1; provider })

      expect(built.size).to eq(sections.size + 2)
    end

    it "grades and assesses in the caller's zone rather than the new thread's default" do
      exercise, response = exercise_and_response
      zones = Queue.new

      Time.use_zone("Asia/Tokyo") do
        review(%w[code_review pattern], exercise: exercise, response: response,
               grade: ->(*) { zones << Time.zone.name; { "rating" => "solid" } },
               assess_difficulty: ->(*, **) { zones << Time.zone.name; {} })
      end

      expect(drained(zones)).to eq([ "Asia/Tokyo" ] * 3)
    end

    it "translates a pseudocode answer before building the day context the grader reads" do
      exercise, response = pseudocode_day
      order = Queue.new

      review(%w[pseudocode_to_code], exercise: exercise, response: response,
             translate: ->(*, **) { order << :translate; "def merged; end" },
             day_context: ->(*) { order << :day_context; "day context" })

      expect(drained(order)).to eq(%i[translate day_context])
      expect(response.reload.translated?("pseudocode_to_code")).to be(true)
    end
  end

  describe "a failed section" do
    it "tags an infrastructure failure rather than losing the sections that graded" do
      exercise, response = exercise_and_response
      grade = lambda do |_user, _exercise, _response, section, _context|
        raise ActiveRecord::ConnectionTimeoutError, "could not obtain a connection" if section == "pattern"

        { "rating" => "solid" }
      end

      results = nil
      expect { results = review(%w[code_review pattern], exercise: exercise, response: response, grade: grade) }
        .not_to raise_error

      expect(results["code_review"][:ok]).to be(true)
      expect(results["pattern"]).to include(ok: false, error_code: "other")
    end

    it "lets a programming error through rather than dressing it up as a retryable failure" do
      exercise, response = exercise_and_response

      was_reporting = Thread.report_on_exception
      Thread.report_on_exception = false

      expect { review(%w[code_review], exercise: exercise, response: response, grade: ->(*) { nil.this_method_does_not_exist }) }
        .to raise_error(NoMethodError)
    ensure
      Thread.report_on_exception = was_reporting
    end

    it "tags a failed section without affecting a successful one" do
      exercise, response = exercise_and_response

      failing_class = Class.new(AiService) do
        def initialize(_api_key = nil, canned_text: "{}")
          @canned_text = canned_text
          @calls = 0
        end

        private

        def call(request)
          @calls += 1
          raise ProviderError::RateLimitError, "rate limited" if request.prompt.include?('"pattern"')
          { text: @canned_text, input_tokens: 1, output_tokens: 1, truncated: false }
        end

        def build_connection = nil
      end
      svc = failing_class.new(canned_text: { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" }.to_json)

      freeze_time do
        results = review(%w[code_review pattern], exercise: exercise, response: response,
                         providers: -> { svc.review_grading_provider })

        expect(results["code_review"][:ok]).to be(true)
        expect(results["pattern"]).to eq(ok: false, error_code: "rate_limit", failure: "short_rate_limit",
                                         provider: failing_class.provider_key, quota_id: nil, retry_after: nil,
                                         failed_at: Time.current)
      end
    end

    it "maps AuthenticationError to its error code" do
      exercise, response = exercise_and_response

      results = review(%w[code_review], exercise: exercise, response: response,
                       grade: ->(*) { raise ProviderError::AuthenticationError, "bad key" })
      expect(results["code_review"][:error_code]).to eq("authentication")
    end

    it "names the provider the error carries, since a fan-out can outlive a key switch" do
      exercise, response = exercise_and_response
      error = ProviderError::RateLimitError.new("busy").tap { |e| e.provider = "gemini" }

      results = review(%w[code_review], exercise: exercise, response: response,
                       grade: ->(*) { raise error }, provider_key: "claude")

      expect(results["code_review"][:provider]).to eq("gemini")
    end

    it "names the grading provider when the error carries none" do
      exercise, response = exercise_and_response

      results = review(%w[code_review], exercise: exercise, response: response,
                       grade: ->(*) { raise ProviderError::RateLimitError, "busy" }, provider_key: "claude")

      expect(results["code_review"][:provider]).to eq("claude")
    end
  end

  describe "an unanswered section" do
    around do |example|
      original = ENV["REVIEW_PROSE_JUDGE"]
      example.run
    ensure
      ENV["REVIEW_PROSE_JUDGE"] = original
    end

    def mixed_day(unanswered_answer)
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "question" => "cr?", "snippet" => "code" },
                       "pattern" => { "title" => "P", "question" => "pat?" },
                       "parsons_problem" => { "title" => "T", "question" => "Q", "blocks" => %w[a b c d e] } }
      )
      answers = { "code_review" => "a" * 20, "pattern" => unanswered_answer }
      [ exercise, DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: answers, submitted_at: Time.current) ]
    end

    let(:graded_reply) do
      ->(*) { { "rating" => "solid", "essential_gaps" => [ 0 ], "rubric" => 2, "missed" => [ "x" ], "correct" => [] } }
    end

    [ [ "blank", "" ], [ "unsaved", nil ], [ "scaffold-only", ExerciseSection::Pattern::DEFAULT_SCAFFOLD.join("\n\n") ] ].each do |name, written|
      it "stores a #{name} section without rating, essential_gaps or rubric, and keeps the answered one whole" do
        exercise, response = mixed_day(written)
        results = review(%w[code_review pattern], exercise: exercise, response: response, grade: graded_reply)

        expect(results["pattern"][:review]).to eq("missed" => [ "x" ], "correct" => [])
        expect(results["code_review"][:review]).to include("rating" => "solid", "missed" => [ "x" ])
        expect(results["code_review"][:review]).to have_key("rubric")
      end
    end

    it "keeps the grade on a short answer, since it is still an answer" do
      exercise, response = mixed_day("N+1?")
      results = review(%w[pattern], exercise: exercise, response: response, grade: graded_reply)

      expect(results["pattern"][:review]).to include("rating" => "solid", "essential_gaps" => [ 0 ], "missed" => [ "x" ])
    end

    it "strips the grade from a scaffold-only answer" do
      exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                       problem_set: { "plan_review" => { "title" => "T", "question" => "Q" } })
      scaffold = ExerciseSection::PlanReview::DEFAULT_SCAFFOLD.join("\n\n")
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                       answers: { "plan_review" => scaffold }, submitted_at: Time.current)
      expect(response).not_to be_answered("plan_review")

      results = review(%w[plan_review], exercise: exercise, response: response, grade: graded_reply)

      expect(results["plan_review"][:review]).to eq("missed" => [ "x" ], "correct" => [])
    end

    it "walks through a Parsons section with no blocks and a saved order, storing no rating" do
      exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                       problem_set: { "parsons_problem" => { "title" => "T", "question" => "Q" } })
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                       answers: { "parsons_problem" => "order:1,0" }, submitted_at: Time.current)
      expect(response).not_to be_answered("parsons_problem")

      results = review(%w[parsons_problem], exercise: exercise, response: response, grade: graded_reply)

      expect(results["parsons_problem"][:review]).to eq("missed" => [ "x" ], "correct" => [])
    end

    it "gives an untouched Parsons section no computed rating" do
      exercise, response = mixed_day("")
      results = review(%w[parsons_problem], exercise: exercise, response: response, grade: graded_reply)

      expect(results["parsons_problem"][:review]).not_to have_key("rating")
    end

    it "does not run the rubric check on an unanswered section" do
      exercise, response = mixed_day("")
      allow(RubricCheck).to receive(:new).and_call_original

      review(%w[pattern], exercise: exercise, response: response, grade: graded_reply)

      expect(RubricCheck).not_to have_received(:new)
    end

    it "still runs the prose judge, which is handed a review with no rating" do
      exercise, response = mixed_day("")
      judged = []
      judge = ->(_user, _kind, graded, **) { judged << graded; ReviewProseVerdict.new(status: :keep) }

      ENV["REVIEW_PROSE_JUDGE"] = "1"
      review(%w[pattern], exercise: exercise, response: response, grade: graded_reply, judge_prose: judge, judges_prose: true)

      expect(judged.size).to eq(1)
      expect(judged.first).not_to have_key("rating")
    end

    it "makes one grade call, one difficulty assessment and one judge call per section" do
      exercise, response = mixed_day("")
      ENV["REVIEW_PROSE_JUDGE"] = "1"
      calls = Queue.new
      review(%w[code_review pattern], exercise: exercise, response: response, judges_prose: true,
             grade: ->(*) { calls << :grade; graded_reply.call },
             assess_difficulty: ->(*, **) { calls << :assess; {} },
             judge_prose: ->(*, **) { calls << :judge; ReviewProseVerdict.new(status: :keep) })

      expect(drained(calls).tally).to eq(grade: 2, assess: 1, judge: 2)
    end
  end

  describe "a computed rating" do
    it "replaces the grader's rating with the kind's computed one" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review"     => { "question" => "q", "snippet" => "s" },
          "pattern"         => { "title" => "t", "question" => "q" },
          "parsons_problem" => { "title" => "T", "question" => "Q", "blocks" => %w[a b c d e] }
        }
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "parsons_problem" => "order:0,1,2,3,4" }, submitted_at: Time.current
      )

      results = review(%w[parsons_problem], exercise: exercise, response: response, grade: ->(*) { { "rating" => "beginner" } })

      expect(results["parsons_problem"][:review]["rating"]).to eq("strong")
    end
  end

  describe "the difficulty assessment" do
    it "merges an assessment into each successfully graded section" do
      exercise, response = exercise_and_response
      difficulty = {
        "code_review" => { "level" => "demanding", "reason" => "The n+1 hides inside an association call." },
        "pattern"     => { "level" => "straightforward", "reason" => "One thing to notice." },
        "challenge"   => { "level" => "moderate", "reason" => "Not asked about today." }
      }

      results = review(%w[code_review pattern], exercise: exercise, response: response,
                       assess_difficulty: ->(*, **) { difficulty })

      expect(results["code_review"][:review]["difficulty"])
        .to eq("level" => "demanding", "reason" => "The n+1 hides inside an association call.")
      expect(results["pattern"][:review]["difficulty"]).to eq("level" => "straightforward", "reason" => "One thing to notice.")
      expect(results.keys).to match_array(%w[code_review pattern])
    end

    it "leaves the grades intact when the assessment fails outright" do
      exercise, response = exercise_and_response

      results = review(%w[code_review pattern], exercise: exercise, response: response,
                       assess_difficulty: ->(*, **) { raise ProviderError::RateLimitError, "rate limited" })

      expect(results["code_review"][:ok]).to be(true)
      expect(results["code_review"][:review]).not_to have_key("difficulty")
      expect(results["pattern"][:ok]).to be(true)
    end

    it "keeps the grades when the assessment raises something outside the AiService hierarchy" do
      exercise, response = exercise_and_response

      results = nil
      expect {
        results = review(%w[code_review pattern], exercise: exercise, response: response,
                         assess_difficulty: ->(*, **) { raise JSON::ParserError, "unexpected token" })
      }.not_to raise_error

      expect(results["code_review"][:ok]).to be(true)
      expect(results["pattern"][:ok]).to be(true)
      expect(results["code_review"][:review]).not_to have_key("difficulty")
    end

    it "leaves without the note rather than letting a hung assessment hold the review" do
      exercise, response = exercise_and_response
      gate = Queue.new

      stub_const("AiService::DIFFICULTY_ASSESSMENT_GRACE_SECONDS", 0.05)

      results = Timeout.timeout(10) do
        review(%w[code_review], exercise: exercise, response: response, assess_difficulty: ->(*, **) { gate.pop })
      end

      expect(results["code_review"][:ok]).to be(true)
      expect(results["code_review"][:review]).not_to have_key("difficulty")
    ensure
      gate << {}
    end
  end

  # A real service grades here; the difficulty thread is stubbed because it would send the same canned reply.
  def graded_by(service, section, exercise, response)
    providers = -> { service.review_grading_provider.with(assess_difficulty: ->(*, **) { {} }) }
    described_class.call(user: user, exercise: exercise, response: response, sections: [ section ],
                         coach: "Rails", providers: providers)[section]
  end

  describe "judging graded reviews" do
    let(:user) { User.create!(email: "graded@example.com", name: "G", provider: "fake", api_keys: { "fake" => "fake-test-key" }) }
    let(:exercise) do
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                            problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_stringify_keys)
    end
    let(:response) do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "The query runs once per row, so preload it." }, submitted_at: Time.current)
    end
    let(:logged) { StringIO.new }
    let(:grade) { FakeService::REVIEW_SECTION.deep_stringify_keys.merge("missed" => [ "SENTINEL-G one.", "SENTINEL-G two." ]) }
    let(:stamped) { grade.merge("rubric" => ReviewedSectionResults::RUBRIC_VERSION) }
    let(:graded_prose) { grade.slice(*DailyResponse::AI_REVIEW_FIELDS.keys, "essential_gaps") }

    around do |example|
      original_logger = Rails.logger
      original_switch = ENV["REVIEW_PROSE_JUDGE"]
      Rails.logger = ActiveSupport::Logger.new(logged)
      example.run
    ensure
      Rails.logger = original_logger
      ENV["REVIEW_PROSE_JUDGE"] = original_switch
    end

    # `judge_reply` is a String, or an exception to raise.
    def graded(judge_reply: { "status" => "keep" }.to_json, grader: grade, provider: FakeService)
      judge_calls = 0
      svc = provider.new("key")
      allow(svc).to receive(:call).and_wrap_original do |_m, request|
        if request.system == ReviewProseJudgePrompt::SYSTEM
          judge_calls += 1
          raise judge_reply if judge_reply.is_a?(Exception)
          { text: judge_reply, input_tokens: 1, output_tokens: 1 }
        else
          { text: grader.to_json, input_tokens: 1, output_tokens: 1 }
        end
      end
      result = graded_by(svc, "code_review", exercise, response)
      [ result, judge_calls ]
    end

    it "keeps an unparseable grade out of the log and the section's error" do
      svc = FakeService.new("key")
      allow(svc).to receive(:call).and_return(text: "SENTINEL-GRADE is not json", input_tokens: 1, output_tokens: 1)
      allow(Rails.logger).to receive(:error)

      result = graded_by(svc, "code_review", exercise, response)

      expect(result[:ok]).to be(false)
      expect(result.values.join).not_to include("SENTINEL")
      expect(Rails.logger).not_to have_received(:error).with(/SENTINEL/)
    end

    def edit_reply
      { "status" => "edit", "issues" => [ { "type" => "verbosity", "evidence" => "SENTINEL-G two." } ],
        "fields" => { "missed" => [ { "from" => [ 0, 1 ], "text" => "One query per row." } ] } }.to_json
    end

    context "with the switch off" do
      it "makes no judge call and returns the grade as returned" do
        result, calls = graded
        expect(calls).to eq(0)
        expect(result).to eq(ok: true, review: stamped)
      end

      it "removes a provider-supplied graded_prose" do
        result, = graded(grader: grade.merge("graded_prose" => { "missed" => "forged" }))
        expect(result[:review]).to eq(stamped)
      end
    end

    context "with the switch on" do
      before { ENV["REVIEW_PROSE_JUDGE"] = "1" }

      it "judges an unanswered section's walkthrough and stores it with no rating, gaps or rubric stamp" do
        response.update!(answers: {})
        result, calls = graded
        expect(calls).to eq(1)
        expect(result[:ok]).to be(true)
        expect(result[:review].keys).not_to include("rating", "essential_gaps", "rubric")
        expect(result[:review]["missed"]).to eq(grade["missed"])
      end

      it "applies an edit, keeps the rating, and stores the grader's prose" do
        result, calls = graded(judge_reply: edit_reply)
        expect(calls).to eq(1)
        expect(result[:ok]).to be(true)
        expect(result[:review]["missed"]).to eq([ "One query per row." ])
        expect(result[:review]["rating"]).to eq(grade["rating"])
        expect(result[:review]["graded_prose"]).to eq(graded_prose)
        expect(result[:review]).not_to have_key("essential_gaps")
        expect(logged.string).to match(/\[review_judge\] user=#{user.id} section=code_review status=edit issues=verbosity merges=\{"missed":\[\[0,1\]\]\}/)
      end

      it "keeps the gap positions in place when the edit left missed alone" do
        next_step_only = { "status" => "edit", "issues" => [ { "type" => "verbosity", "evidence" => "Review the referenced" } ],
                           "fields" => { "next_step" => "Reread the concept." } }.to_json
        result, = graded(judge_reply: next_step_only)

        expect(result[:review]["next_step"]).to eq("Reread the concept.")
        expect(result[:review]["essential_gaps"]).to eq(grade["essential_gaps"])
        expect(result[:review]["graded_prose"]).not_to have_key("essential_gaps")
      end

      it "keeps the sanitized grade on keep, dropping a forged graded_prose" do
        result, = graded(grader: grade.merge("graded_prose" => { "missed" => "forged" }))
        expect(result[:review]).to eq(stamped)
      end

      it "replaces a forged graded_prose with its own on edit" do
        result, = graded(judge_reply: edit_reply, grader: grade.merge("graded_prose" => { "missed" => "forged" }))
        expect(result[:review]["graded_prose"]).to eq(graded_prose)
      end

      {
        "plain prose" => [ "SENTINEL-G The review looks fine to me.", "invalid_json" ],
        "malformed JSON" => [ "{\"status\": \"edit\", SENTINEL-G", "invalid_json" ],
        "a JSON array" => [ "[\"SENTINEL-G\"]", "invalid_json" ],
        "a JSON string" => [ "\"ok\"", "invalid_json" ],
        "an unexpected error" => [ ArgumentError.new("SENTINEL-G boom"), "other" ],
        "a verdict the boundary refuses" => [ { "status" => "edit", "issues" => [], "fields" => {} }.to_json, "invalid_output" ],
        "a timeout" => [ ProviderError::TimeoutError.new("SENTINEL-G slow"), "timeout" ],
        "a refusal" => [ ProviderError::RefusalError.new("SENTINEL-G declined"), "refusal" ],
        "a truncated reply" => [ ProviderError::TruncatedResponseError.new("SENTINEL-G cut off"), "truncated" ],
        "a rate limit" => [ ProviderError::RateLimitError.new("SENTINEL-G busy"), "rate_limit" ]
      }.each do |name, (reply, reason)|
        it "falls back to the sanitized grade on #{name}, logging a code and no review text" do
          result, = graded(judge_reply: reply, grader: grade.merge("graded_prose" => "forged"))
          expect(result).to eq(ok: true, review: stamped)
          expect(logged.string).to include("[review_judge_fallback] user=#{user.id} section=code_review reason=#{reason}")
          expect(logged.string).not_to include("SENTINEL-G")
        end
      end

      it "stores an array and keeps the original string when the grader's missed is a string" do
        reply = { "status" => "edit", "issues" => [ { "type" => "verbosity", "evidence" => "SENTINEL-G" } ],
                  "fields" => { "missed" => [ { "from" => [ 0 ], "text" => "Rewritten." } ] } }.to_json
        result, = graded(judge_reply: reply, grader: grade.merge("missed" => "One long missed string."))
        expect(result[:review]["missed"]).to eq([ "Rewritten." ])
        expect(result[:review]["graded_prose"]["missed"]).to eq("One long missed string.")
      end

      it "never judges for a provider that does not judge" do
        result, calls = graded(provider: GeminiService)
        expect(calls).to eq(0)
        expect(result[:review]).to eq(stamped)
      end
    end
  end

  describe "the essential-gap check on each graded section" do
    let(:user) { User.create!(email: "rubric@example.com", name: "R", provider: "fake", api_keys: { "fake" => "fake-test-key" }, skill_level: "senior") }
    let(:service) { FakeService.new("key") }
    let(:logged) { StringIO.new }
    let(:saved_exercise) do
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                            problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_stringify_keys)
    end
    let(:parsons_blocks) { FakeService::EXERCISE_PROBLEM_SET.deep_stringify_keys["parsons_problem"]["blocks"].size }
    let(:saved_response) do
      DailyResponse.create!(user: user, daily_exercise: saved_exercise, date: Date.current,
                            answers: { "code_review" => "The query runs once per row, so preload it.", "parsons_problem" => "order:#{(0...parsons_blocks).to_a.join(",")}" },
                            submitted_at: Time.current)
    end

    around do |example|
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(logged)
      example.run
    ensure
      Rails.logger = original
    end

    def graded(review, section: "code_review")
      allow(service).to receive(:call).and_return(text: review.to_json, input_tokens: 1, output_tokens: 1)
      graded_by(service, section, saved_exercise, saved_response)
    end

    let(:base) { { "rating" => "solid", "correct" => [], "missed" => [ "SECRET-M polish note." ], "better_questions" => [], "next_step" => "x", "improved_code" => "" } }

    it "logs agreement and keeps the checked positions" do
      result = graded(base.merge("essential_gaps" => []))

      expect(result[:review]["essential_gaps"]).to eq([])
      expect(logged.string).to include("[rubric_check] user=#{user.id} section=code_review rating=solid essential=0 missed=1 agrees=true")
    end

    it "logs a solid rating that lists an essential gap, and leaves the rating alone" do
      result = graded(base.merge("essential_gaps" => [ 0 ]))

      expect(result[:review]["rating"]).to eq("solid")
      expect(logged.string).to include("rating=solid essential=1 missed=1 agrees=false")
    end

    it "drops positions it cannot read rather than storing them, and logs that it could not check" do
      result = graded(base.merge("essential_gaps" => [ 7 ]))

      expect(result[:review]).not_to have_key("essential_gaps")
      expect(logged.string).to include("rating=solid essential=unknown missed=1 agrees=unknown")
    end

    it "never logs review text" do
      graded(base.merge("essential_gaps" => []))

      expect(logged.string).not_to include("SECRET-M")
    end

    it "logs a rating outside the vocabulary as invalid rather than echoing it" do
      graded(base.merge("rating" => "SECRET-M excellent", "essential_gaps" => []))

      expect(logged.string).to include("rating=invalid")
      expect(logged.string).not_to include("SECRET-M")
    end

    it "stamps the rubric version on every graded review, replacing any copy the provider sent" do
      result = graded(base.merge("essential_gaps" => [], "rubric" => 99))

      expect(result[:review]["rubric"]).to eq(ReviewedSectionResults::RUBRIC_VERSION)
    end

    it "stamps a computed rating too, since the same prompt graded its prose" do
      result = graded(base.merge("essential_gaps" => []), section: "parsons_problem")

      expect(result[:review]["rubric"]).to eq(ReviewedSectionResults::RUBRIC_VERSION)
    end

    it "treats a parsons section with no blocks as unanswered, so the grader's rating is neither checked nor kept" do
      saved_exercise.problem_set["parsons_problem"].delete("blocks")
      saved_exercise.save!

      result = graded(base.merge("essential_gaps" => []), section: "parsons_problem")

      expect(logged.string).not_to include("[rubric_check]")
      expect(result[:review].keys).not_to include("rating", "essential_gaps", "rubric")
    end

    it "skips a kind whose rating is computed, dropping any positions the grader sent" do
      result = graded(base.merge("essential_gaps" => [ 0 ]), section: "parsons_problem")

      expect(logged.string).not_to include("[rubric_check]")
      expect(result[:review]).not_to have_key("essential_gaps")
    end
  end
end
