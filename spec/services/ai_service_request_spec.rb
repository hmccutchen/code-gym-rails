require "rails_helper"

RSpec.describe AiService, "request values" do
  defaults = { read_timeout: AiService::READ_TIMEOUT, max_tokens: nil,
               cache_system: false, single_attempt: false, allow_truncated: false }

  # Written from the constants, apart from CALL_PROFILES, so a profile row that drifts fails here.
  call_site_settings = {
    "generate_exercise"           => defaults.merge(read_timeout: AiService::GENERATION_READ_TIMEOUT),
    "retry_section"               => defaults.merge(read_timeout: AiService::RETRY_READ_TIMEOUT),
    "review_response"             => defaults.merge(cache_system: true, read_timeout: AiService::REVIEW_READ_TIMEOUT),
    "assess_difficulty"           => defaults.merge(max_tokens: AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS),
    "generate_concept_reference"  => defaults.merge(read_timeout: AiService::CONCEPT_REFERENCE_READ_TIMEOUT),
    "generate_recognition_guide"  => defaults.merge(read_timeout: AiService::CONCEPT_REFERENCE_READ_TIMEOUT),
    "explain_concept_differently" => defaults.merge(max_tokens: AiService::CONCEPT_ALTERNATE_MAX_TOKENS),
    "explain_differently"         => defaults,
    "review_follow_up"            => defaults,
    "duck_thread"                 => defaults.merge(max_tokens: AiService::DUCK_RESPONSE_MAX_TOKENS,
                                                   cache_system: true, allow_truncated: true),
    "pseudocode_critique"         => defaults.merge(max_tokens: AiService::PSEUDOCODE_CRITIQUE_MAX_TOKENS),
    "pseudocode_translate"        => defaults,
    "judge_section"               => defaults.merge(max_tokens: AiService::JUDGE_MAX_TOKENS),
    "judge_review"                => defaults.merge(max_tokens: AiService::REVIEW_JUDGE_MAX_TOKENS,
                                                   read_timeout: AiService::REVIEW_JUDGE_READ_TIMEOUT, single_attempt: true)
  }.freeze

  def settings_of(request)
    { read_timeout: request.read_timeout, max_tokens: request.max_tokens, cache_system: request.cache_system,
      single_attempt: request.single_attempt, allow_truncated: request.allow_truncated }
  end

  describe "CALL_PROFILES" do
    it "profiles exactly the purposes a usage row may record" do
      expect(AiService::CALL_PROFILES.keys.sort).to eq(ApiUsage::PURPOSES.sort)
    end

    it "is checked here against every purpose" do
      expect(call_site_settings.keys.sort).to eq(ApiUsage::PURPOSES.sort)
    end
  end

  describe ".request_for" do
    it "refuses a purpose with no profile" do
      expect { AiService.request_for("unknown_purpose", system: "s", prompt: "p") }
        .to raise_error(KeyError, /unknown_purpose/)
    end

    it "refuses a blocking request for a purpose with no blocking timeout" do
      expect { AiService.request_for("judge_review", system: "s", prompt: "p", blocking: true) }
        .to raise_error(ArgumentError, /judge_review/)
    end

    it "picks the synchronous timeout for a blocking generation" do
      request = AiService.request_for("generate_exercise", system: "s", prompt: "p", blocking: true)

      expect(settings_of(request)).to eq(call_site_settings["generate_exercise"].merge(read_timeout: AiService::SYNC_GENERATION_READ_TIMEOUT))
      expect(request.read_timeout).to eq(AiService::SYNC_GENERATION_READ_TIMEOUT)
    end

    it "carries the per-call values through unchanged" do
      history = [ { role: "user", content: "earlier" } ]
      schema  = { "type" => "object" }

      request = AiService.request_for("judge_section", system: "s", prompt: "p", history: history, response_schema: schema)

      expect(request).to have_attributes(purpose: "judge_section", system: "s", prompt: "p",
                                         history: history, response_schema: schema)
    end

    it "sends no history and no schema unless the call site passes them" do
      expect(AiService.request_for("retry_section", system: "s", prompt: "p"))
        .to have_attributes(history: [], response_schema: nil)
    end

    call_site_settings.each do |purpose, settings|
      it "gives #{purpose} its pinned settings" do
        expect(settings_of(AiService.request_for(purpose, system: "s", prompt: "p"))).to eq(settings)
      end
    end
  end

  describe "Request.build" do
    it "applies the defaults #call_and_log applied before" do
      expect(AiService::Request.build(system: "s", prompt: "p")).to have_attributes(
        purpose: nil, system: "s", prompt: "p", history: [], response_schema: nil, max_tokens: nil,
        read_timeout: AiService::READ_TIMEOUT, cache_system: false, single_attempt: false, allow_truncated: false
      )
    end

    it "takes any setting explicitly, outside any profile" do
      request = AiService::Request.build(purpose: "explain_differently", system: "s", prompt: "p",
                                         max_tokens: 60, single_attempt: true, allow_truncated: true)

      expect(request).to have_attributes(purpose: "explain_differently", max_tokens: 60, single_attempt: true, allow_truncated: true)
    end

    it "refuses a setting it does not know" do
      expect { AiService::Request.build(system: "s", prompt: "p", blocking: true) }.to raise_error(ArgumentError, /blocking/)
    end
  end

  it "is built from a profile in one place under app/, .request_for" do
    callers = Dir[Rails.root.join("app/**/*.rb")].select { |path| File.read(path).include?("Request.build(") }
    factory = File.read(Rails.root.join("app/services/ai_service.rb"))[/^  def self\.request_for.*?^  end$/m]

    expect(callers.map { |path| Pathname(path).relative_path_from(Rails.root).to_s }).to eq([ "app/services/ai_service.rb" ])
    expect(File.read(callers.sole).scan("Request.build(").size).to eq(1)
    expect(factory).to include("Request.build(")
  end

  describe "the request each caller hands to #call_and_log" do
    let(:user) { User.create!(email: "requests@example.com", name: "R", provider: "fake", api_keys: { "fake" => "fake-test-key" }) }
    let(:service) { FakeService.new("fake-key") }
    let(:exercise) do
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                            problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_dup)
    end
    let(:response) do
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            ai_review: { "code_review" => { "missed" => [ "The association is loaded per row" ] } })
    end
    let(:reference) do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "t", explanation: "e", code_example: "c", senior_lens: "s")
    end

    def requests_sent_while
      requests = []
      allow_any_instance_of(FakeService).to receive(:call_and_log).and_wrap_original { |m, *args| requests << args.last; m.call(*args) }
      yield
      requests
    end

    def request_sent_for(purpose, &driver)
      requests = requests_sent_while(&driver)
      requests.find { |request| request.purpose == purpose } ||
        raise("no #{purpose} request was sent; saw #{requests.map(&:purpose).inspect}")
    end

    def drive(purpose)
      case purpose
      when "generate_exercise"           then service.generate_exercise(user)
      when "retry_section"               then retry_one_section
      when "review_response"             then service.review_sections(user, exercise, response, sections: %w[code_review])
      when "assess_difficulty"           then service.send(:assess_difficulty, user, exercise, sections: %w[code_review])
      when "generate_concept_reference"  then service.generate_concept_reference(user, "n_plus_one", "ruby_rails")
      when "generate_recognition_guide"  then service.generate_recognition_guide(user, "code_smell")
      when "explain_concept_differently" then service.explain_concept_differently(user, reference)
      when "explain_differently"         then service.explain_differently(user, exercise, response, section: "code_review")
      when "review_follow_up"            then service.answer_follow_up(user, exercise, response, section: "code_review", question: "Why?")
      when "duck_thread"                 then service.duck_response(user, exercise, section: "code_review", message: "Where do I start?")
      when "pseudocode_critique"         then service.critique_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "sort then walk")
      when "pseudocode_translate"        then service.translate_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "sort then walk")
      when "judge_section"               then service.judge_section(user, ExerciseSection::CodeReview, exercise.problem_set["code_review"], rung: "senior", locked: false)
      when "judge_review"                then service.judge_review_prose(user, ExerciseSection::CodeReview, response.ai_review["code_review"], coach: "Rails")
      end
    end

    def retry_one_section
      draft = service.send(:draft_exercise, user, language: "ruby_rails", blocking: false)
      service.send(:retry_section, user, "ruby_rails", draft, ExerciseSection::Pattern, "service_objects")
    end

    call_site_settings.each do |purpose, settings|
      it "sends #{purpose} with its pinned settings" do
        expect(settings_of(request_sent_for(purpose) { drive(purpose) })).to eq(settings)
      end
    end

    call_site_settings.each_key do |purpose|
      it "sends #{purpose} a system prompt the oracle marker table maps back to it" do
        system = request_sent_for(purpose) { drive(purpose) }.system
        shares_generation_prompt = purpose == "retry_section"

        expect(purpose_for(system)).to eq(shares_generation_prompt ? "generate_exercise" : purpose)
      end
    end

    it "sends a blocking generation on the synchronous timeout" do
      request = request_sent_for("generate_exercise") { service.generate_exercise(user, blocking: true) }

      expect(settings_of(request)).to eq(call_site_settings["generate_exercise"].merge(read_timeout: AiService::SYNC_GENERATION_READ_TIMEOUT))
    end

    it "sends prior turns from the two conversational callers" do
      thread = [ { "role" => "user", "content" => "What's slow here?" }, { "role" => "assistant", "content" => "Look at the loop." } ]

      duck = request_sent_for("duck_thread") { service.duck_response(user, exercise, section: "code_review", message: "Still stuck", thread: thread) }
      follow_up = request_sent_for("review_follow_up") do
        service.answer_follow_up(user, exercise, response, section: "code_review", question: "Why?", thread: thread)
      end

      expect(duck.history.size).to eq(thread.size)
      expect(follow_up.history.size).to eq(thread.size)
    end
  end
end
