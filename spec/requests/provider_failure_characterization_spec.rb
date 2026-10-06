require "rails_helper"

# What each provider-calling path shows when Gemini fails, stubbed at the HTTP
# level through GeminiService's real retry configuration, so the request count
# and the text that reaches the page are the real ones. The bodies live in
# spec/fixtures/provider_errors and follow Google's documented error shape;
# the Interactions API's real 429 is unconfirmed until the capacity probe
# records one, and the fixtures are replaced with what it captures.
#
# One example per failure class per path. Every sentence comes from the
# provider_failures locale table through ProviderFailureText; nothing here
# repeats provider text, a status code, socket detail or a key.
RSpec.describe "Provider failures as users see them", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  GOOGLE_QUOTA_MESSAGE = "You exceeded your current quota, please check your plan and billing details."

  def fixture(name) = Rails.root.join("spec/fixtures/provider_errors", name).read

  FAILURES = {
    "daily-quota 429"  => { status: 429, body: "gemini_429_daily.json", headers: { "Retry-After" => "3600" } },
    "per-minute 429"   => { status: 429, body: "gemini_429_minute.json" },
    "invalid key 400"  => { status: 400, body: "gemini_400_api_key_invalid.json" },
    "revoked key 403"  => { status: 403, body: "gemini_403_permission_denied.json" },
    "outage 503"       => { status: 503, body: "gemini_503_outage.html" },
    "timeout"          => { timeout: true }
  }.freeze

  KINDS = {
    "daily-quota 429" => "daily_limit",
    "per-minute 429"  => "short_rate_limit",
    "invalid key 400" => "bad_key",
    "revoked key 403" => "bad_key",
    "outage 503"      => "outage",
    "timeout"         => "timeout"
  }.freeze

  # Each class's sentence on each surface, for a Gemini key at 10am Eastern on
  # Tuesday: the free allowance then resets at 3am Eastern on Wednesday, and
  # the per-minute fixture asks for a 20-second wait.
  def expected(kind, outcome, saved: nil, wait: "a minute")
    reset = { "daily_limit" => "The allowance resets at 3:00 am your time, Wednesday.",
              "short_rate_limit" => "Try again in about #{wait}." }[kind]
    title = { "daily_limit"      => "Your Gemini key has used today's free allowance, so #{outcome}.",
              "short_rate_limit" => "Gemini is limiting requests right now, so #{outcome}.",
              "bad_key"          => "Gemini didn't accept your API key, so #{outcome}.",
              "outage"           => "Gemini isn't answering right now, so #{outcome}.",
              "timeout"          => "Gemini took too long to answer, so #{outcome}." }.fetch(kind)
    next_step = { "daily_limit" => "Try again after that, or add a paid key in Setup.",
                  "bad_key"     => "Check the key in Setup.",
                  "outage"      => "Nothing was lost. Try again in a few minutes.",
                  "timeout"     => "Try again." }[kind]
    { full: [ title, saved, reset, next_step ].compact.join(" "), brief: [ title, reset || next_step ].compact.join(" ") }
  end

  let(:user) do
    User.create!(email: "gemini@example.com", name: "Gem", time_zone: "America/New_York",
                 learning_track: LearningTrack::OFF).tap do |u|
      u.update!(provider: "gemini", api_keys: { "gemini" => "AIzaTestKey" })
    end
  end

  # Tuesday, 10am in the user's zone: a weekday, past the batch's 8am gate.
  around { |example| travel_to(Time.utc(2026, 10, 6, 14)) { example.run } }

  before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) }

  # Returns a counter of requests made. Every GeminiService instance, including
  # the per-thread copies grade_section builds, gets this connection.
  def stub_gemini(failure)
    requests = 0
    conn = Faraday.new do |f|
      f.request :retry, GeminiService::RETRY_OPTIONS
      f.adapter :test do |stub|
        stub.post(GeminiService::API_URL) do
          requests += 1
          raise Faraday::TimeoutError, "Net::ReadTimeout with #<TCPSocket:(closed)>" if failure[:timeout]

          [ failure[:status], failure.fetch(:headers, {}), fixture(failure[:body]) ]
        end
      end
    end
    allow_any_instance_of(GeminiService).to receive(:build_connection).and_return(conn)
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:warn)
    -> { requests }
  end

  def create_exercise(problem_set = { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } })
    DailyExercise.create!(user: user, date: Date.current, problem_set: problem_set,
                          generated_at: Time.current, language: "ruby_rails")
  end

  def expect_clean(text)
    expect(text).not_to include(GOOGLE_QUOTA_MESSAGE, "API key not valid", "AIza", "TCPSocket", "Net::", "503", "429", "leaked")
  end

  describe "generation" do
    # A daily 429 arrives with a Retry-After past faraday-retry's ceiling, so it
    # is tried once; the per-minute 429 and the outage are tried three times.
    { "daily-quota 429" => 1, "per-minute 429" => 3, "invalid key 400" => 1, "revoked key 403" => 1, "outage 503" => 3, "timeout" => 1 }
      .each do |failure, request_count|
      it "on-demand generation under a #{failure} stores the kind and shows its sentence with a Try again button" do
        requests = stub_gemini(FAILURES[failure])
        kind = KINDS[failure]

        GenerateDailyExercisesJob.new.perform(user_id: user.id)

        user.reload
        expect(user.last_generation_failure).to eq(kind)
        expect(user.last_generation_error).to be_nil
        expect(requests.call).to eq(request_count)
        expect(ApiUsage.count).to eq(1)
        expect(ApiUsage.last).to have_attributes(purpose: "generate_exercise", provider: "gemini", tokens_in: 0, tokens_out: 0)

        login_as(user)
        get root_path
        sentence = expected(kind, "nothing was generated")[:full]
        expect(response.body).to include(ERB::Util.html_escape("Couldn't generate today's exercises."))
        expect(response.body).to include(ERB::Util.html_escape(sentence))
        expect(response.body).to include("Try again")
        expect_clean(sentence)
      end
    end

    it "the nightly batch records the same kind, and the status endpoint renders the sentence" do
      user
      stub_gemini(FAILURES["daily-quota 429"])

      GenerateDailyExercisesJob.new.perform

      expect(user.reload.last_generation_failure).to eq("daily_limit")
      expect(ApiUsage.last).to have_attributes(failure: "rate_limit", http_status: 429, quota_id: "GenerateRequestsPerDayPerProjectPerModel-FreeTier")
      login_as(user)
      get dashboard_status_path
      expect(response.parsed_body).to eq("status" => "failed", "message" => expected("daily_limit", "nothing was generated")[:full])
    end

    it "regeneration under a daily-quota 429 keeps today's set, releases the claim and names the set" do
      exercise = create_exercise
      exercise.update!(regenerating_since: Time.current)
      stub_gemini(FAILURES["daily-quota 429"])

      RegenerateExerciseJob.new.perform(user_id: user.id)

      expect(exercise.reload.regenerating_since).to be_nil
      expect(exercise.regenerated_at).to be_nil
      expect(user.reload.last_generation_failure).to eq("daily_limit")
      login_as(user)
      get root_path
      expect(response.body).to include(ERB::Util.html_escape(expected("daily_limit", "the new set wasn't generated")[:full]))
      expect(response.body).not_to include(ERB::Util.html_escape("Couldn't generate a new set:"))
    end

    it "keeps rendering a message stored as text, as rows from before kinds were stored are" do
      user.update!(last_generation_error_date: Date.current, last_generation_error: "The AI provider is rate-limiting requests — try again shortly.")
      login_as(user)

      get root_path

      expect(response.body).to include(ERB::Util.html_escape("The AI provider is rate-limiting requests — try again shortly."))
    end
  end

  describe "the judge" do
    let(:fake_user) { create_fake_provider_user }

    it "ships the unedited draft and records rate_limit when every judge call is a 429" do
      allow_any_instance_of(FakeService).to receive(:judge_section)
        .and_raise(AiService::RateLimitError.new(GOOGLE_QUOTA_MESSAGE, http_status: 429))

      result = AiService.for(fake_user).generate_judged_exercise(fake_user, language: "ruby_rails")

      expect(result.dropped_sections).to be_empty
      expect(result.outcomes.values.map { |o| o[:fallback] }.uniq).to eq([ "rate_limit" ])
    end
  end

  describe "the review" do
    def submitted_response
      exercise = create_exercise
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 },
                            section_ratings: { "code_review" => "right_level" },
                            submitted_at: Time.current)
    end

    KINDS.each do |failure, kind|
      it "under a #{failure} keeps the answers, frees the claim, stores the kind and flashes its sentence" do
        daily_response = submitted_response
        stub_gemini(FAILURES[failure])
        login_as(user)

        post review_response_path(daily_response)

        sentence = expected(kind, "the review didn't run", saved: "Your answers are saved.")[:full]
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq(sentence)
        expect_clean(sentence)
        daily_response.reload
        expect(daily_response.answers["code_review"]).to eq("a" * 20)
        expect(daily_response.submitted?).to be(true)
        expect(daily_response.reviewed?).to be(false)
        expect(daily_response.reviewing?).to be(false)
        expect(daily_response.review_errors["code_review"]).to include("kind" => kind)
        expect(daily_response.review_errors["code_review"]).not_to have_key("message")

        get root_path
        expect(response.body).to include("Get Gemini review")
        expect(response.body).to include(ERB::Util.html_escape(sentence))
      end
    end

    it "swallows a difficulty-check 429 and reviews without the difficulty note" do
      daily_response = submitted_response
      review = { rating: "solid", correct: "ok", missed: "", better_questions: "", next_step: "", improved_code: "", essential_gaps: [] }
      body = { "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => review.to_json } ] } ],
               "usage" => { "total_input_tokens" => 1, "total_output_tokens" => 1 } }.to_json
      allow_any_instance_of(GeminiService).to receive(:build_connection).and_return(
        Faraday.new { |f| f.adapter(:test) { |stub| stub.post(GeminiService::API_URL) { [ 200, {}, body ] } } }
      )
      allow_any_instance_of(GeminiService).to receive(:assess_difficulty)
        .and_raise(AiService::RateLimitError.new(GOOGLE_QUOTA_MESSAGE, http_status: 429))
      login_as(user)

      post review_response_path(daily_response)

      expect(flash[:notice]).to be_present
      expect(daily_response.reload.ai_review.dig("code_review", "rating")).to eq("solid")
      expect(daily_response.ai_review.dig("code_review", "difficulty")).to be_nil
    end
  end

  describe "the JSON endpoints" do
    def reviewed_response
      exercise = create_exercise
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            ai_review: { "code_review" => { "rating" => "solid", "missed" => [] } })
    end

    def expect_failure_json(kind, outcome)
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["failure"]).to eq(kind)
      expect(response.parsed_body["error"]).to eq(expected(kind, outcome)[:brief])
      expect_clean(response.parsed_body["error"])
    end

    KINDS.each do |failure, kind|
      it "the duck under a #{failure} answers 503 with the kind and its sentence" do
        create_exercise
        stub_gemini(FAILURES[failure])
        login_as(user)

        post duck_thread_responses_path, params: { section: "code_review", message: "Why?" }, as: :json

        expect_failure_json(kind, "the thinking partner didn't answer")
      end

      it "a follow-up under a #{failure} answers 503 and stores no turn" do
        daily_response = reviewed_response
        stub_gemini(FAILURES[failure])
        login_as(user)

        post follow_ups_response_path(daily_response), params: { section: "code_review", question: "What index?" }, as: :json

        expect_failure_json(kind, "your question wasn't answered")
        expect(ReviewFollowUp.count).to eq(0)
      end

      it "explain differently on a review under a #{failure} answers 503" do
        daily_response = reviewed_response
        stub_gemini(FAILURES[failure])
        login_as(user)

        post explain_differently_response_path(daily_response), params: { section: "code_review" }, as: :json

        expect_failure_json(kind, "that explanation didn't come back")
      end

      it "explain differently on a concept reference under a #{failure} answers 503" do
        reference = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                                             tagline: "t", explanation: "e", code_example: "c", senior_lens: "s")
        stub_gemini(FAILURES[failure])
        login_as(user)

        post explain_differently_concept_reference_path(reference), params: { prior_alternates: [] }, as: :json

        expect_failure_json(kind, "that explanation didn't come back")
      end

      it "a pseudocode critique under a #{failure} answers 503 and releases its round" do
        create_exercise("code_review" => { "question" => "q", "snippet" => "s" },
                        "pseudocode_to_code" => { "title" => "t", "problem_statement" => "Reverse a list in place." })
        stub_gemini(FAILURES[failure])
        login_as(user)

        post pseudocode_critique_responses_path, params: { section: "pseudocode_to_code", pseudocode: "loop and swap ends" }, as: :json

        expect_failure_json(kind, "the critique didn't run")
        expect(user.daily_responses.first&.pseudocode_rounds.to_h.dig("pseudocode_to_code", "critiqued_at")).to be_nil
      end
    end
  end

  describe "Learn references and ladders" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    KINDS.each do |failure, kind|
      it "a write-up under a #{failure} writes nothing and tells the page why" do
        stub_gemini(FAILURES[failure])

        GenerateConceptReferenceJob.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)

        expect(ConceptReference.count).to eq(0)
        login_as(user)
        get learn_concept_status_path(bucket: "ruby_rails", concept: "n_plus_one", awaiting: "guide")
        expect(response.parsed_body).to eq("ready" => false, "failed" => kind,
                                           "message" => expected(kind, "the write-up didn't finish")[:brief])
        expect_clean(response.parsed_body["message"])
      end
    end

    it "a ladder rewrite under a daily-quota 429 leaves the shared row unchanged" do
      reference = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                                           tagline: "t", explanation: "e", code_example: "c", senior_lens: "s",
                                           guide_plain_language: "g", guide_worked_example: "w", guide_pitfalls: "p")
      stub_gemini(FAILURES["daily-quota 429"])

      GenerateConceptReferenceJob.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id, refresh: true)

      expect(reference.reload.generation_version).to eq(0)
      expect(reference.ladder?).to be(false)
    end

    it "the Write up the rest backfill still reports nothing when its jobs fail" do
      stub_gemini(FAILURES["daily-quota 429"])
      login_as(user)

      perform_enqueued_jobs { post prepare_learn_path }

      expect(response).to redirect_to(learn_path)
      expect(flash[:notice]).to eq("Writing them up now — they'll appear as each one finishes.")
      expect(ConceptReference.count).to eq(0)
      expect(RecognitionGuide.count).to eq(0)
    end
  end
end
