require "rails_helper"

RSpec.describe AiService do
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  describe "request timeout budget" do
    # #review claims the row for REVIEW_CLAIM_STALE_AFTER and only then lets a
    # retry through. If the request can outlast the claim, a second review
    # starts while the first is still running and bills the same sections
    # twice — so this asserts the two stay in a safe relationship rather than
    # drifting apart.
    #
    # The longest request is a pseudocode day's. #translate_before_grading runs
    # before the fan-out (the day context every grading thread shares is built
    # from its result), and only then do the grades start. Sections are graded
    # in parallel, so however many there are they add one call's worst case.
    # The difficulty note runs alongside everything and then gets
    # DIFFICULTY_ASSESSMENT_GRACE_SECONDS once grading is done.
    #
    # Each call's worst case is AiService.call_budget_seconds at its own read
    # timeout, plus an open timeout per attempt, which that method leaves out.
    # That holds for the grade even though its budget makes a timeout final:
    # a 429, 5xx or 529 still retries, and it can arrive just before the read
    # timeout on every attempt.
    TRANSLATIONS_BEFORE_GRADING = 1

    # Provider time excludes usage writes, translation persistence, parsing,
    # thread scheduling, and the controller's final lock/save. Reserve a minute
    # for that work; this is headroom, not a deadline on database waits.
    REVIEW_OVERHEAD_SECONDS = 1.minute.to_i

    def worst_case_call_seconds(read_timeout)
      AiService.call_budget_seconds(read_timeout) + ((AiService::RETRY_MAX + 1) * AiService::OPEN_TIMEOUT)
    end

    def provider_review_budget_seconds
      (TRANSLATIONS_BEFORE_GRADING * worst_case_call_seconds(AiService::READ_TIMEOUT)) +
        worst_case_call_seconds(AiService::REVIEW_READ_TIMEOUT) +
        AiService::DIFFICULTY_ASSESSMENT_GRACE_SECONDS
    end

    it "keeps the provider budget below the review claim window" do
      expect(provider_review_budget_seconds).to be < DailyResponse::REVIEW_CLAIM_STALE_AFTER.to_i
    end

    it "reserves non-provider time before a review claim can be reclaimed" do
      remaining = DailyResponse::REVIEW_CLAIM_STALE_AFTER.to_i - provider_review_budget_seconds

      expect(remaining).to be >= REVIEW_OVERHEAD_SECONDS
    end

    # Round up only after reserving overhead, so minute rounding cannot consume
    # the margin or leave a crashed review locked longer than necessary.
    it "rounds the provider budget plus overhead up to the next whole minute" do
      minimum_claim_seconds = provider_review_budget_seconds + REVIEW_OVERHEAD_SECONDS

      expect(DailyResponse::REVIEW_CLAIM_STALE_AFTER).to eq(((minimum_claim_seconds / 60) + 1).minutes)
    end

    # The provider retry options are what call_budget_seconds describes, so the
    # arithmetic above holds only while both providers still read them.
    it "reads the retry limits call_budget_seconds assumes" do
      [ ClaudeService, GeminiService ].each do |provider|
        expect(provider::RETRY_OPTIONS).to include(max: AiService::RETRY_MAX, max_interval: AiService::RETRY_MAX_INTERVAL)
      end
    end

    # faraday-retry caps the computed backoff at max_interval and only then
    # adds its random jitter, so a sleep can exceed RETRY_MAX_INTERVAL unless
    # the largest computed backoff plus that jitter stays under it.
    it "keeps every computed backoff sleep within RETRY_MAX_INTERVAL" do
      [ ClaudeService, GeminiService ].each do |provider|
        options = provider::RETRY_OPTIONS
        largest = options[:interval] * (options[:backoff_factor]**(AiService::RETRY_MAX - 1))
        jitter  = options[:interval_randomness] * options[:interval]

        expect([ largest, options[:max_interval] ].min + jitter).to be <= AiService::RETRY_MAX_INTERVAL
      end
    end

    # The translation count above is a claim about the app, not a free
    # parameter: exactly one kind translates before it is graded, so a second
    # one appearing has to come back here and to the claim window rather than
    # quietly lengthening the worst case.
    it "has one section kind whose grade waits on a call of its own" do
      expect(ExerciseSection.all.count(&:translated_before_grading?)).to eq(TRANSLATIONS_BEFORE_GRADING)
    end

    # The review budget above is driven by #review holding a request thread and
    # a claim on the row. Generation shares neither constraint: it is always
    # enqueued (GenerateDailyExercisesJob), so it runs on the worker and holds
    # no claim. It is also the single largest response we ever ask for — one
    # non-streaming call carrying every section — against a model that thinks
    # before it answers, so nothing arrives on the socket for far longer than a
    # per-section review takes. Sharing READ_TIMEOUT made every morning's
    # generation die on Net::ReadTimeout.
    it "gives generation a budget far larger than the short-call one" do
      expect(AiService::GENERATION_READ_TIMEOUT).to be > AiService::READ_TIMEOUT * 4
    end
  end

  # Minimal concrete subclass so AiService's shared logic can be exercised
  # without a real network call to any provider.
  let(:double_class) do
    Class.new(AiService) do
      attr_writer :canned_text, :input_tokens, :output_tokens, :truncated
      attr_reader :last_read_timeout, :last_max_tokens, :last_prompt

      # #review_sections builds a fresh service per section thread, so a plain
      # ivar on the instance under test never sees those calls.
      def self.read_timeouts_by_purpose
        @read_timeouts_by_purpose ||= []
      end

      def initialize(api_key_or_config = nil, canned_text: "{}", input_tokens: 1, output_tokens: 1, truncated: false)
        config = api_key_or_config.is_a?(Hash) ? api_key_or_config : { canned_text: canned_text, input_tokens: input_tokens, output_tokens: output_tokens, truncated: truncated }
        @api_key       = config
        @canned_text   = config.fetch(:canned_text, "{}")
        @input_tokens  = config.fetch(:input_tokens, 1)
        @output_tokens = config.fetch(:output_tokens, 1)
        @truncated     = config.fetch(:truncated, false)
      end

      private

      def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
        @last_read_timeout = read_timeout
        @last_max_tokens   = max_tokens
        @last_prompt       = prompt
        self.class.read_timeouts_by_purpose << [ purpose, read_timeout ]
        { text: @canned_text, input_tokens: @input_tokens, output_tokens: @output_tokens, truncated: @truncated }
      end

      def build_connection
        nil
      end
    end
  end

  # Like double_class, but answers the grading prompt and the difficulty prompt
  # differently. #review_sections issues both, and keeping them separable here
  # is the point — a fake that returned one canned body for every system prompt
  # could not tell a merged assessment from a coincidence.
  let(:assessing_class) do
    Class.new(AiService) do
      def initialize(api_key_or_config = nil, review: {}, difficulty: {})
        config = api_key_or_config.is_a?(Hash) ? api_key_or_config : { review: review, difficulty: difficulty }
        @api_key    = config
        @review     = config.fetch(:review, {})
        @difficulty = config.fetch(:difficulty, {})
      end

      private

      def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
        text =
          if system.include?("rating how hard")
            raise AiService::RateLimitError, "rate limited" if @difficulty == :raise

            @difficulty.to_json
          else
            @review.to_json
          end

        { text: text, input_tokens: 1, output_tokens: 1, truncated: false }
      end

      def build_connection
        nil
      end
    end
  end

  let(:service) { double_class.new }

  # reject_missing_sections! now requires whatever DailyPlan actually rolls for
  # third/fourth to be present. Most examples below care about one section, not
  # about the roll, so this pads every third/fourth alternative with an empty
  # placeholder — satisfying whichever outcome an unstubbed roll picks, without
  # pinning it. Overrides replace a placeholder with the content a test cares
  # about; #present? only requires a Hash, so an untouched placeholder is inert.
  def full_problem_set(overrides = {})
    base = { "code_review" => {}, "pattern" => {} }
    (ExerciseSection.thirds + ExerciseSection.fourths).each { |kind| base[kind.key] = {} }
    base.merge(overrides)
  end

  # The single-shot purposes must never acquire conversational turns without
  # being noticed. This test names them by scanning the source directly — more
  # robust than inferring the roster from snapshots — and asserts the complete
  # list by name rather than by subtraction, so a regex miss that loses one
  # purpose becomes visible as a failure instead of passing silently. No count
  # is stated here on purpose: the roster is the list itself, and a number
  # beside it is one more thing that can go stale as purposes are added.
  describe "single-shot purposes" do
    SINGLE_SHOT_PURPOSES = %w[
      generate_exercise
      retry_section
      review_response
      assess_difficulty
      generate_concept_reference
      explain_concept_differently
      explain_differently
      pseudocode_critique
      pseudocode_translate
      judge_section
    ].freeze

    it "covers every purpose except the two conversational ones" do
      all_purposes = File.read(Rails.root.join("app/services/ai_service.rb"))
                         .scan(/purpose: "(\w+)"/).flatten.uniq

      expect(all_purposes).to contain_exactly(*SINGLE_SHOT_PURPOSES, "review_follow_up", "duck_thread")
    end

    # The roster above is a list of names. On its own it would still pass if one
    # of these callers started sending turns, so it cannot be the guarantee — it
    # only fixes which callers the guarantee has to cover. This drives every
    # public entry point behind those purposes and asserts the history reaching
    # #call is empty every time. #review_sections stands for two of them: it
    # issues the grading call and the difficulty assessment, and both must stay
    # single-shot.
    #
    # The purposes the run logged are asserted against the same roster, so a
    # caller that stops being exercised here fails rather than quietly dropping
    # out of the guarantee while the empty-history assertion still passes on
    # whatever is left.
    it "reaches the provider with no conversational history, from every one of them" do
      calls = []
      spy_class = Class.new(double_class) do
        define_method(:call) do |system:, prompt:, cache_system: false,
                                 read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil|
          calls << [ purpose, history ]
          super(system: system, prompt: prompt, cache_system: cache_system,
                read_timeout: read_timeout, max_tokens: max_tokens, history: history, purpose: purpose)
        end
      end

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
        answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
        ai_review: { "code_review" => { "missed" => [ "The association is loaded per row" ] } }
      )
      review_json = {
        "rating" => "solid", "correct" => [], "missed" => [],
        "better_questions" => [], "next_step" => "", "improved_code" => ""
      }.to_json
      reference_json = {
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s"
      }.to_json

      spy_class.new(canned_text: full_problem_set.to_json).generate_exercise(user)
      retry_draft = spy_class.new(canned_text: full_problem_set.to_json)
                            .send(:draft_exercise, user, language: "ruby_rails", blocking: false)
      spy_class.new(canned_text: { "pattern" => FakeService::EXERCISE_PROBLEM_SET["pattern"].deep_dup }.to_json)
               .send(:retry_section, user, "ruby_rails", retry_draft, ExerciseSection::Pattern, "service_objects")
      spy_class.new(canned_text: review_json).review_sections(user, exercise, response, sections: %w[code_review])
      spy_class.new(canned_text: reference_json).generate_concept_reference(user, "n_plus_one", "ruby_rails")
      spy_class.new(canned_text: "Another framing.")
               .explain_differently(user, exercise, response, section: "code_review")
      spy_class.new(canned_text: "A different angle on the same concept.")
               .explain_concept_differently(user, ConceptReference.create!(
                 concept: "n_plus_one", language: "ruby_rails",
                 tagline: "t", explanation: "e", code_example: "c", senior_lens: "s"
               ))
      spy_class.new(canned_text: { gaps_found: false, gaps: [] }.to_json)
               .critique_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "sort then walk")
      spy_class.new(canned_text: "def x\nend")
               .translate_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "sort then walk")
      spy_class.new(canned_text: { status: "keep" }.to_json)
               .judge_section(user, ExerciseSection::CodeReview, exercise.problem_set["code_review"],
                 rung: "senior", locked: false)

      expect(ApiUsage.pluck(:purpose).uniq).to match_array(SINGLE_SHOT_PURPOSES)
      expect(calls.map(&:first)).to include(*SINGLE_SHOT_PURPOSES)
      expect(calls.select { |purpose, _history| SINGLE_SHOT_PURPOSES.include?(purpose) }.map(&:last)).to all(be_empty)
    end
  end

  # A truncated response is still a billed response, so the usage row has to
  # be written before the failure propagates — otherwise cost tracking
  # silently under-counts exactly the calls that burn a full output budget.
  describe "truncated provider responses" do
    it "records the billed usage before raising" do
      svc = double_class.new(input_tokens: 900, output_tokens: 8_000, truncated: true)

      expect {
        expect { svc.generate_exercise(user) }.to raise_error(AiService::TruncatedResponseError)
      }.to change { ApiUsage.where(purpose: "generate_exercise").count }.by(1)

      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(900)
      expect(usage.tokens_out).to eq(8_000)
    end

    it "records the billed usage before raising on a refusal, and names the category" do
      svc = double_class.new(canned_text: nil, input_tokens: 700, output_tokens: 0)
      allow(svc).to receive(:call).and_return(text: nil, input_tokens: 700, output_tokens: 0, truncated: false, refusal: "cyber")

      expect {
        expect { svc.generate_exercise(user) }.to raise_error(AiService::RefusalError, /cyber/)
      }.to change { ApiUsage.where(purpose: "generate_exercise").count }.by(1)

      expect(ApiUsage.last.tokens_in).to eq(700)
    end

    it "raises TruncatedResponseError rather than a confusing parse error" do
      svc = double_class.new(canned_text: '{"code_review": {"correct": ["half a sen', truncated: true)

      expect {
        svc.generate_exercise(user)
      }.to raise_error(AiService::TruncatedResponseError, /output token limit/i)
    end

    it "records usage before raising on a prose entry point too" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: { "code_review" => { "question" => "q" } })
      resp = DailyResponse.new(answers: {}, ai_review: { "code_review" => {} })
      svc = double_class.new(canned_text: "a cut-off expl", truncated: true)

      expect {
        expect {
          svc.explain_differently(user, exercise, resp, section: "code_review", prior_alternates: [])
        }.to raise_error(AiService::TruncatedResponseError)
      }.to change { ApiUsage.where(purpose: "explain_differently").count }.by(1)
    end
  end

  # Assembly only. Each kind's own fragment is specified at its interface in
  # spec/models/exercise_section_spec.rb, and the exact assembled bytes are
  # pinned in spec/services/generation_prompt_characterization_spec.rb.
  describe "#exercise_schema_for" do
    it "defaults to ruby_rails when no language is given" do
      expect(service.send(:exercise_schema_for)).to eq(service.send(:exercise_schema_for, "ruby_rails"))
    end

    it "defaults to the challenge third and the plan_review fourth" do
      schema = JSON.parse(service.send(:exercise_schema_for, "ruby_rails"))
      expect(schema.keys).to eq(%w[code_review pattern challenge plan_review])
    end

    # The kinds assert their own label interpolation; this asserts AiService
    # resolves the day's language and hands it down, which no kind can check.
    # code_review's own fragment stopped restating the label (see
    # ExerciseSection::CodeReview.schema_fragment), so security_review — whose
    # fragment does interpolate it directly — is the one that still proves the
    # thread here.
    it "threads the day's language label into the kinds that take one" do
      expect(service.send(:exercise_schema_for, "ruby_rails", third: :security_review)).to include("Ruby/Rails code")
      expect(service.send(:exercise_schema_for, "javascript", third: :security_review)).to include("JavaScript/React code")
    end

    it "assembles the rolled third and fourth in slot order" do
      schema = JSON.parse(service.send(:exercise_schema_for, "ruby_rails", third: :architecture, fourth: :ambiguity_hunt))
      expect(schema.keys).to eq(%w[code_review pattern architecture ambiguity_hunt])
    end
  end

  describe "generating a short day" do
    let(:user) { User.create!(email: "short@example.com", name: "Short") }

    it "asks for only the chosen sections in the schema" do
      schema = JSON.parse(service.send(:exercise_schema_for, "ruby_rails", third: :challenge,
                                       fourth: nil, pattern: nil))

      expect(schema.keys).to eq(%w[code_review challenge])
    end

    it "writes no fourth-section reinforcement line when there is no fourth" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge, fourth: nil)

      expect(prompt).not_to include("Fourth-section")
    end

    it "gives guidance for each chosen section and no others" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: nil, fourth: nil, pattern: nil)

      expect(prompt).to include("code_review concept from this vocabulary")
      expect(prompt).not_to include("PARSONS PROBLEM")
    end
  end

  describe "diagram syntax constraints" do
    it "constrains the diagram to a narrow, parseable subset" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :architecture)

      expect(prompt).to match(/flowchart TD|graph LR/)
      expect(prompt).to match(/8 nodes|eight nodes/i)
      expect(prompt).to match(/empty string/i) # opting out is allowed
    end
  end

  describe "#build_system_prompt" do
    it "focuses on Rails patterns for ruby_rails" do
      prompt = service.send(:build_system_prompt, "ruby_rails")
      expect(prompt).to include("senior Rails engineering coach")
      expect(prompt).to include("N+1 queries")
    end

    it "focuses on JavaScript/React patterns for javascript" do
      prompt = service.send(:build_system_prompt, "javascript")
      expect(prompt).to include("senior JavaScript/React engineering coach")
      expect(prompt).to include("hooks")
    end

    it "defaults to ruby_rails when no language is given" do
      expect(service.send(:build_system_prompt)).to eq(service.send(:build_system_prompt, "ruby_rails"))
    end

    it "raises instead of silently falling back on an unsupported language" do
      expect { service.send(:build_system_prompt, "mixed") }
        .to raise_error(AiService::Error, /Unsupported generation language/)
    end
  end

  describe "RAILS_CONCEPTS" do
    it "is a frozen 44-entry vocabulary" do
      expect(AiService::RAILS_CONCEPTS.size).to eq(44)
      expect(AiService::RAILS_CONCEPTS).to be_frozen
      expect(AiService::RAILS_CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end

    it "includes the two Rails security concepts chosen for real depth" do
      expect(AiService::RAILS_CONCEPTS).to include("mass_assignment_protection", "sql_injection_prevention")
    end

    it "includes the two test-analysis concepts added for code_review's occasional test-file variant" do
      expect(AiService::RAILS_CONCEPTS).to include("over_mocking", "testing_implementation_not_behavior")
    end

    it "excludes secure_secrets_handling and dependency_vulnerability_management as poor fits for this app's format" do
      expect(AiService::RAILS_CONCEPTS).not_to include("secure_secrets_handling", "dependency_vulnerability_management")
    end
  end

  describe "JS_CONCEPTS" do
    it "is a frozen 46-entry vocabulary" do
      expect(AiService::JS_CONCEPTS.size).to eq(46)
      expect(AiService::JS_CONCEPTS).to be_frozen
      expect(AiService::JS_CONCEPTS).to include("closures", "prototype_chain", "hooks_dependencies")
    end

    it "includes the two JS security concepts chosen for real depth" do
      expect(AiService::JS_CONCEPTS).to include("xss_prevention", "insecure_client_storage")
    end

    it "includes the two test-analysis concepts added for code_review's occasional test-file variant" do
      expect(AiService::JS_CONCEPTS).to include("over_mocking", "testing_implementation_not_behavior")
    end
  end

  describe "CODE_SMELL_CONCEPTS" do
    it "names smells rather than the remedies the vocabularies already carry" do
      expect(AiService::CODE_SMELL_CONCEPTS)
        .to contain_exactly("god_object", "primitive_obsession", "shotgun_surgery", "feature_envy")
      expect(AiService::CODE_SMELL_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(AiService::RAILS_CONCEPTS).to include(*AiService::CODE_SMELL_CONCEPTS)
      expect(AiService::JS_CONCEPTS).to include(*AiService::CODE_SMELL_CONCEPTS)
    end
  end

  describe "OO_DESIGN_CONCEPTS" do
    it "names the three principles that survived the depth and relevance filters" do
      expect(AiService::OO_DESIGN_CONCEPTS)
        .to contain_exactly("open_closed", "dependency_inversion", "composition_over_inheritance")
      expect(AiService::OO_DESIGN_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(AiService::RAILS_CONCEPTS).to include(*AiService::OO_DESIGN_CONCEPTS)
      expect(AiService::JS_CONCEPTS).to include(*AiService::OO_DESIGN_CONCEPTS)
    end

    # single_responsibility duplicates god_object from the rule side, and
    # program_to_interface duplicates dependency_inversion. Both were cut
    # rather than shipped as twins; liskov_substitution and
    # interface_segregation were cut on relevance, not to complete SOLID.
    it "omits the candidates that duplicated an existing concept or failed the relevance filter" do
      expect(AiService::RAILS_CONCEPTS).not_to include(
        "single_responsibility", "program_to_interface", "encapsulate_what_varies",
        "liskov_substitution", "interface_segregation"
      )
      expect(AiService::JS_CONCEPTS).not_to include(
        "single_responsibility", "program_to_interface", "encapsulate_what_varies",
        "liskov_substitution", "interface_segregation"
      )
    end

    it "stays out of the language-agnostic vocabularies, so its references show real code" do
      AiService::LANGUAGE_AGNOSTIC_VOCABULARIES.each do |vocabulary|
        expect(vocabulary).not_to include(*AiService::OO_DESIGN_CONCEPTS)
      end
    end
  end

  describe "#code_smell_naming_guidance" do
    let(:user) { User.create!(email: "smells@example.com", name: "Smells") }
    let(:service) { FakeService.new("fake-key") }

    it "names the group from the constant and asks for recognition, not a patch" do
      guidance = service.send(:code_smell_naming_guidance)

      expect(guidance).to include(*AiService::CODE_SMELL_CONCEPTS)
      expect(guidance).to match(/naming and locating/i)
    end

    it "is stated once in the generation prompt" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails")

      expect(prompt.scan("god_object").size).to be >= 1
      expect(prompt).to include(service.send(:code_smell_naming_guidance))
    end

    # challenge draws the full language vocabulary, and its answer is code. A
    # blanket "never patch, just name it" would hand the provider a coding
    # exercise whose answer must not be code.
    it "gives challenge a refactoring shape rather than a prose answer" do
      guidance = service.send(:code_smell_naming_guidance)

      expect(guidance).to match(/challenge/i)
      expect(guidance).to match(/restructur/i)
    end
  end

  describe "#oo_design_violation_guidance" do
    let(:user) { User.create!(email: "principles@example.com", name: "Principles") }
    let(:service) { FakeService.new("fake-key") }

    it "names the group from the constant" do
      expect(service.send(:oo_design_violation_guidance)).to include(*AiService::OO_DESIGN_CONCEPTS)
    end

    # code_review and challenge have no section_grading_note and are graded by
    # the generic rubric, which has nothing to put in "missed" unless the
    # section planted something missable. A principle invites an essay without
    # this constraint.
    it "requires one findable violation the section can be graded against" do
      guidance = service.send(:oo_design_violation_guidance)

      expect(guidance).to match(/exactly one specific, findable violation/i)
      expect(guidance).to match(/gradeable/i)
    end

    it "asks the discussion sections for the violation named rather than rewritten" do
      expect(service.send(:oo_design_violation_guidance)).to match(/rather than a rewrite/i)
    end

    # challenge draws the full language vocabulary, and its schema asks what to
    # implement with a code answer. A blanket "never rewrite" would hand the
    # provider a coding exercise whose answer must not be code.
    it "gives challenge a corrected-design shape rather than a prose answer" do
      guidance = service.send(:oo_design_violation_guidance)

      expect(guidance).to match(/challenge section is the exception/i)
      expect(guidance).to match(/writing the corrected design IS the answer/i)
    end

    # A test-file code_review must also exhibit a real test smell, and every
    # concept in this group is selectable there — code_review's :test_file
    # vocabulary is the day's full language list minus the data-modeling group.
    # A clause naming only one principle leaves the other two with two
    # unrelated requirements and no stated way to satisfy both (issue #114),
    # so the idiom is asserted per concept and derived from the constant: a
    # fourth principle has to arrive with its own idiom or fail here.
    it "gives every selectable design principle a test-file idiom" do
      clause = service.send(:oo_design_violation_guidance)[/on a test-file code_review.*?(?=The challenge section)/m]

      expect(clause).to be_present
      AiService::OO_DESIGN_CONCEPTS.each do |concept|
        expect(clause).to include(concept), "no test-file idiom for #{concept}"
      end
    end

    # The general rule, stated independently of any one principle: a smell
    # planted next to the violation satisfies both instructions separately and
    # is exactly what #114 reported.
    it "requires the planted test smell to be the violation itself" do
      expect(service.send(:oo_design_violation_guidance)).to match(/rather than sit beside it/i)
    end

    it "is stated once in the generation prompt, for every section rather than per kind" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails")

      expect(prompt).to include(service.send(:oo_design_violation_guidance))
      expect(prompt.scan("The OO design-principle concepts").size).to eq(1)
    end
  end

  describe "MODULE_DESIGN_CONCEPTS" do
    it "names the three module-design shapes that survived the overlap filter" do
      expect(AiService::MODULE_DESIGN_CONCEPTS)
        .to contain_exactly("shallow_module", "pass_through_method", "temporal_decomposition")
      expect(AiService::MODULE_DESIGN_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(AiService::RAILS_CONCEPTS).to include(*AiService::MODULE_DESIGN_CONCEPTS)
      expect(AiService::JS_CONCEPTS).to include(*AiService::MODULE_DESIGN_CONCEPTS)
    end

    # information_leakage is shotgun_surgery named from the cause side and
    # generates the same section; special_general_mixture's findable violation
    # is the conditional an open_closed section already shows. Both were cut
    # rather than shipped as twins, on the precedent that cut
    # single_responsibility from OO_DESIGN_CONCEPTS.
    it "omits the candidates that duplicated an existing concept" do
      %w[information_leakage special_general_mixture].each do |cut|
        expect(AiService::RAILS_CONCEPTS).not_to include(cut)
        expect(AiService::JS_CONCEPTS).not_to include(cut)
      end
    end

    it "stays out of the language-agnostic vocabularies, so its references show real code" do
      AiService::LANGUAGE_AGNOSTIC_VOCABULARIES.each do |vocabulary|
        expect(vocabulary).not_to include(*AiService::MODULE_DESIGN_CONCEPTS)
      end
    end
  end

  describe "#module_design_depth_guidance" do
    let(:user) { User.create!(email: "modules@example.com", name: "Modules") }
    let(:service) { FakeService.new("fake-key") }

    it "names the group from the constant" do
      expect(service.send(:module_design_depth_guidance)).to include(*AiService::MODULE_DESIGN_CONCEPTS)
    end

    # Depth is a property of an interface rather than a defect in a result, so
    # this is the group most able to produce a section with nothing missable in
    # it — and code_review and challenge are graded by the generic rubric,
    # which then has nothing to put in "missed".
    it "requires one findable instance the section can be graded against" do
      guidance = service.send(:module_design_depth_guidance)

      expect(guidance).to match(/exactly one specific, findable/i)
      expect(guidance).to match(/gradeable/i)
    end

    it "asks the discussion sections for the shape named rather than rewritten" do
      expect(service.send(:module_design_depth_guidance)).to match(/rather than a rewrite/i)
    end

    # challenge draws the full language vocabulary, and its schema asks what to
    # implement with a code answer. A blanket "never rewrite" would hand the
    # provider a coding exercise whose answer must not be code.
    it "gives challenge a deepened-module shape rather than a prose answer" do
      guidance = service.send(:module_design_depth_guidance)

      expect(guidance).to match(/challenge section is the exception/i)
      expect(guidance).to match(/writing the deeper module IS the answer/i)
    end

    # A test-file code_review must also exhibit a test smell, and these
    # concepts are selectable there — the same collision #code_smell_naming_guidance
    # already resolves with one clause.
    it "says what the shape looks like on a test-file code_review" do
      expect(service.send(:module_design_depth_guidance)).to match(/test-file code_review/i)
    end

    it "is stated once in the generation prompt, for every section rather than per kind" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails")

      expect(prompt).to include(service.send(:module_design_depth_guidance))
      expect(prompt.scan("The module-design concepts").size).to eq(1)
    end
  end

  describe "SILENT_CORRECTNESS_CONCEPTS" do
    it "names the four invariant defects that survived the overlap filter" do
      expect(AiService::SILENT_CORRECTNESS_CONCEPTS)
        .to contain_exactly("allocation_rounding", "semantic_input_validation",
                            "cache_key_completeness", "deterministic_ordering")
      expect(AiService::SILENT_CORRECTNESS_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(AiService::RAILS_CONCEPTS).to include(*AiService::SILENT_CORRECTNESS_CONCEPTS)
      expect(AiService::JS_CONCEPTS).to include(*AiService::SILENT_CORRECTNESS_CONCEPTS)
    end

    it "stays out of the language-agnostic vocabularies, so its references show real code" do
      AiService::LANGUAGE_AGNOSTIC_VOCABULARIES.each do |vocabulary|
        expect(vocabulary).not_to include(*AiService::SILENT_CORRECTNESS_CONCEPTS)
      end
    end

    # Each names a discipline to reach for — largest-remainder distribution, a
    # complete key, a total order — so the remedy lens is the right one, the
    # same call the design principles got. The defect is the violation; the
    # concept is not.
    it "stays off the anti-shape list, so its reference keeps the remedy lens" do
      expect(AiService::ANTI_SHAPE_CONCEPTS).not_to include(*AiService::SILENT_CORRECTNESS_CONCEPTS)
    end

    # deterministic_ordering and PSEUDOCODE_TO_CODE_CONCEPTS' ambiguous_ordering
    # are adjacent by name and must stay in separate buckets: one is code whose
    # order is underdetermined at runtime, the other a plan that never states
    # an order at all.
    it "shares no entry with the fourth-slot or architecture vocabularies" do
      [ AiService::ARCHITECTURE_CONCEPTS, AiService::PLAN_REVIEW_CONCEPTS,
        AiService::AMBIGUITY_HUNT_CONCEPTS, AiService::PSEUDOCODE_TO_CODE_CONCEPTS ].each do |vocabulary|
        expect(vocabulary & AiService::SILENT_CORRECTNESS_CONCEPTS).to be_empty
      end
    end
  end

  describe "#silent_correctness_guidance" do
    let(:user) { User.create!(email: "invariants@example.com", name: "Invariants") }
    let(:service) { FakeService.new("fake-key") }

    it "names the group from the constant" do
      expect(service.send(:silent_correctness_guidance)).to include(*AiService::SILENT_CORRECTNESS_CONCEPTS)
    end

    # The inverse of every other group's failure mode: these risk a section
    # whose defect is too visible. Code that raises is no longer an example of
    # a defect that survives every check the engineer makes.
    it "requires code that runs clean and still answers wrongly" do
      guidance = service.send(:silent_correctness_guidance)

      expect(guidance).to match(/runs clean/i)
      expect(guidance).to match(/no exception/i)
      expect(guidance).to match(/still produce a wrong answer/i)
    end

    it "draws the line between cache_key_completeness and the caching concept" do
      expect(service.send(:silent_correctness_guidance))
        .to match(/never about whether to cache at all/i)
    end

    # validations shares a vocabulary line with semantic_input_validation on
    # every Rails day, so the same boundary the caching neighbour gets is owed
    # here: mastery is keyed on the tag, and a section tagged the wrong side of
    # this line schedules reinforcement for a concept the engineer never saw.
    it "draws the line between semantic_input_validation and the validations concept" do
      expect(service.send(:silent_correctness_guidance))
        .to match(/never about one that is absent or malformed, which is validations/i)
    end

    # A negative total is legitimate in a refund, credit, or reversal domain.
    # Requiring every generated exercise to reject one would put a wrong answer
    # key in front of the engineer, so the rejection case defers to the
    # scenario's own domain rather than asserting a universal rule.
    it "leaves whether a negative total is meaningless to the scenario's domain" do
      guidance = service.send(:silent_correctness_guidance)

      expect(guidance).to match(/an input its own scenario makes meaningless/i)
      expect(guidance).to match(/in a domain where only positive quantities exist/i)
    end

    # The group is selectable on a test_file code_review, whose content
    # instruction demands a planted test smell — the same collision the code
    # smell, OO design, and module design rules each close explicitly.
    it "says what the defect looks like on a test-file code_review" do
      guidance = service.send(:silent_correctness_guidance)

      expect(guidance).to match(/test-file code_review/i)
      expect(guidance).to match(/computed the same wrong way as the subject/i)
    end

    # The group sits in JS_CONCEPTS too, so a calibration that only ever says
    # "query" and "pagination" leaves a javascript day under-calibrated.
    it "calibrates deterministic_ordering for a comparator as well as a query" do
      expect(service.send(:silent_correctness_guidance)).to match(/sort or comparator/i)
    end

    # pattern shows no code, and challenge's answer IS code — the same two
    # idiom carve-outs the other group rules make.
    it "gives pattern and challenge their own answer shapes" do
      guidance = service.send(:silent_correctness_guidance)

      expect(guidance).to match(/a pattern, which shows no code/i)
      expect(guidance).to match(/challenge section is the exception/i)
    end

    it "is stated once in the generation prompt, for every section rather than per kind" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails")

      expect(prompt).to include(service.send(:silent_correctness_guidance))
      expect(prompt.scan("The silent-correctness concepts").size).to eq(1)
    end
  end

  describe "DOMAIN_MODELING_CONCEPTS" do
    it "names the two model-level concepts the four-book audit found uncovered" do
      expect(AiService::DOMAIN_MODELING_CONCEPTS)
        .to contain_exactly("ubiquitous_language", "aggregate_boundaries")
      expect(AiService::DOMAIN_MODELING_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(AiService::RAILS_CONCEPTS).to include(*AiService::DOMAIN_MODELING_CONCEPTS)
      expect(AiService::JS_CONCEPTS).to include(*AiService::DOMAIN_MODELING_CONCEPTS)
    end

    it "stays out of the language-agnostic vocabularies, so its references show real code" do
      AiService::LANGUAGE_AGNOSTIC_VOCABULARIES.each do |vocabulary|
        expect(vocabulary).not_to include(*AiService::DOMAIN_MODELING_CONCEPTS)
      end
    end

    # Both name a discipline to reach for — name it as the domain names it,
    # make one object the entry point for a set of writes — so the remedy lens
    # is the right one, the same call the design principles got.
    it "stays off the anti-shape list, so its reference keeps the remedy lens" do
      expect(AiService::ANTI_SHAPE_CONCEPTS).not_to include(*AiService::DOMAIN_MODELING_CONCEPTS)
    end

    # Neither has two defensible sides, so the reference must contrast a
    # failure mode with its fix. TRADEOFF_CONCEPTS' own classification gate
    # only covers ARCHITECTURE_CONCEPTS, so nothing else would catch this —
    # and a reference is generated once and cached forever.
    it "takes the failure-mode contrast rather than the tradeoff one" do
      expect(AiService::TRADEOFF_CONCEPTS).not_to include(*AiService::DOMAIN_MODELING_CONCEPTS)

      config = service.send(:config_for, "ruby_rails")
      AiService::DOMAIN_MODELING_CONCEPTS.each do |concept|
        prompt = service.send(:build_concept_reference_prompt, concept, config)

        expect(prompt).to include("corrected version"), "#{concept} got the tradeoff contrast"
      end
    end

    it "shares no entry with the fourth-slot or architecture vocabularies" do
      [ AiService::ARCHITECTURE_CONCEPTS, AiService::PLAN_REVIEW_CONCEPTS,
        AiService::AMBIGUITY_HUNT_CONCEPTS, AiService::PSEUDOCODE_TO_CODE_CONCEPTS ].each do |vocabulary|
        expect(vocabulary & AiService::DOMAIN_MODELING_CONCEPTS).to be_empty
      end
    end

    it "shares no entry with the other shared language-vocabulary groups" do
      [ AiService::DATA_MODELING_CONCEPTS, AiService::META_SKILL_CONCEPTS,
        AiService::CODE_SMELL_CONCEPTS, AiService::OO_DESIGN_CONCEPTS,
        AiService::MODULE_DESIGN_CONCEPTS, AiService::SILENT_CORRECTNESS_CONCEPTS ].each do |vocabulary|
        expect(vocabulary & AiService::DOMAIN_MODELING_CONCEPTS).to be_empty
      end
    end
  end

  describe "#domain_modeling_guidance" do
    let(:user) { User.create!(email: "domain@example.com", name: "Domain") }
    let(:service) { FakeService.new("fake-key") }

    it "names the group from the constant" do
      expect(service.send(:domain_modeling_guidance)).to include(*AiService::DOMAIN_MODELING_CONCEPTS)
    end

    # The failure mode this group shares with the design principles and the
    # module-design concepts: code_review and challenge carry no
    # section_grading_note, so the generic rubric has nothing to put in
    # "missed" unless the section contains something missable.
    it "requires one specific findable instance rather than a topic to discuss" do
      guidance = service.send(:domain_modeling_guidance)

      expect(guidance).to match(/exactly one specific, findable instance/i)
      expect(guidance).to match(/gradeable against it/i)
    end

    # Without the domain's own word on the page there is nothing for the code
    # to contradict, and the section degenerates into "rename this variable".
    it "requires the scenario to establish the domain's word before the code contradicts it" do
      expect(service.send(:domain_modeling_guidance))
        .to match(/establish the domain's own word before the code contradicts it/i)
    end

    # reading_for_intent shares a vocabulary line with ubiquitous_language on
    # every day either can be tagged, and mastery is keyed on the tag rather
    # than on what the section contained.
    it "draws the line between ubiquitous_language and reading_for_intent" do
      expect(service.send(:domain_modeling_guidance))
        .to match(/keeps this apart from reading_for_intent/i)
    end

    it "draws the line between aggregate_boundaries and transaction_safety" do
      expect(service.send(:domain_modeling_guidance))
        .to match(/never about whether a transaction was opened, which is transaction_safety/i)
    end

    it "gives pattern and challenge their own answer shapes" do
      guidance = service.send(:domain_modeling_guidance)

      expect(guidance).to match(/a pattern, which shows no code/i)
      expect(guidance).to match(/challenge section is the exception/i)
    end

    # The test_file code_review mode demands a planted test smell, so a group
    # rule that does not say what the smell IS reads as a contradiction there.
    it "gives the test-file code_review mode its own idiom" do
      expect(service.send(:domain_modeling_guidance))
        .to match(/on a test-file code_review the planted test smell must BE the instance/i)
    end

    it "is stated once in the generation prompt, for every section rather than per kind" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails")

      expect(prompt).to include(service.send(:domain_modeling_guidance))
      expect(prompt.scan("The domain-modeling concepts").size).to eq(1)
    end
  end

  describe "TYPESCRIPT_FLAVORED_CONCEPTS" do
    it "is a frozen 4-entry subset of JS_CONCEPTS" do
      expect(AiService::TYPESCRIPT_FLAVORED_CONCEPTS.size).to eq(4)
      expect(AiService::TYPESCRIPT_FLAVORED_CONCEPTS).to be_frozen
      expect(AiService::TYPESCRIPT_FLAVORED_CONCEPTS - AiService::JS_CONCEPTS).to be_empty
      expect(AiService::TYPESCRIPT_FLAVORED_CONCEPTS).to contain_exactly(
        "generics", "type_guards_narrowing", "union_intersection_types", "mapped_conditional_types"
      )
    end
  end

  describe "DATA_MODELING_CONCEPTS" do
    it "holds the five data-modeling concepts" do
      expect(AiService::DATA_MODELING_CONCEPTS).to eq(%w[
        missing_index wrong_cardinality missing_constraint
        denormalization_tradeoffs unsafe_migration
      ])
    end

    it "is frozen" do
      expect(AiService::DATA_MODELING_CONCEPTS).to be_frozen
    end

    it "overlaps no other closed vocabulary" do
      [ AiService::ARCHITECTURE_CONCEPTS, AiService::PLAN_REVIEW_CONCEPTS,
        AiService::AMBIGUITY_HUNT_CONCEPTS, AiService::RAILS_SECURITY_CONCEPTS,
        AiService::JS_SECURITY_CONCEPTS ].each do |other|
        expect(AiService::DATA_MODELING_CONCEPTS & other).to be_empty
      end
    end

    it "is folded into both language vocabularies, which stay frozen" do
      expect(AiService::RAILS_CONCEPTS).to include(*AiService::DATA_MODELING_CONCEPTS)
      expect(AiService::JS_CONCEPTS).to include(*AiService::DATA_MODELING_CONCEPTS)
      expect(AiService::RAILS_CONCEPTS).to be_frozen
      expect(AiService::JS_CONCEPTS).to be_frozen
    end
  end

  describe "schema_artifact in LANGUAGE_CONFIG" do
    it "names a per-language artifact for the two real languages" do
      expect(AiService::LANGUAGE_CONFIG["ruby_rails"][:schema_artifact]).to eq("a Rails migration")
      expect(AiService::LANGUAGE_CONFIG["javascript"][:schema_artifact])
        .to eq("a Prisma schema change, with the migration it generates")
    end

    # Mirrors test_framework: absent for the pseudo-language buckets, which
    # never generate a code_review section.
    it "is absent for the pseudo-language buckets" do
      %w[architecture plan_review ambiguity_hunt].each do |bucket|
        expect(AiService::LANGUAGE_CONFIG[bucket][:schema_artifact]).to be_nil
      end
    end
  end

  describe "ARCHITECTURE_CONCEPTS" do
    it "is a frozen 15-entry language-independent vocabulary" do
      expect(AiService::ARCHITECTURE_CONCEPTS.size).to eq(15)
      expect(AiService::ARCHITECTURE_CONCEPTS).to be_frozen
      expect(AiService::ARCHITECTURE_CONCEPTS).to include("service_boundaries", "failure_mode_design", "idempotency_at_scale")
    end

    it "is not mixed into any per-language generation vocabulary" do
      expect(AiService::RAILS_CONCEPTS & AiService::ARCHITECTURE_CONCEPTS).to be_empty
      expect(AiService::JS_CONCEPTS & AiService::ARCHITECTURE_CONCEPTS).to be_empty
    end

    # Chapter 2's causes of complexity, at the level the architecture section
    # already asks about. change_amplification was cut with them: it is
    # coupling_cohesion's symptom at the same altitude, and shotgun_surgery
    # already carries the code-level version in both language vocabularies —
    # which the disjointness rule above exists to keep from happening.
    it "carries the two complexity causes that duplicate no existing entry" do
      expect(AiService::COMPLEXITY_CAUSE_CONCEPTS).to contain_exactly("cognitive_load", "unknown_unknowns")
      expect(AiService::ARCHITECTURE_CONCEPTS).to include(*AiService::COMPLEXITY_CAUSE_CONCEPTS)
      expect(AiService::ARCHITECTURE_CONCEPTS).not_to include("change_amplification")
    end
  end

  describe "SCENARIO_DOMAINS" do
    it "is a frozen list of exactly these 9 scenario flavors, including a rare legacy-GraphQL entry" do
      expect(AiService::SCENARIO_DOMAINS).to be_frozen
      expect(AiService::SCENARIO_DOMAINS.size).to eq(9)
      expect(AiService::SCENARIO_DOMAINS).to contain_exactly(
        "background_job_processing", "api_versioning_and_deprecation",
        "activerecord_query_construction", "component_state_management",
        "data_export_and_reporting", "webhook_delivery", "rate_limiting",
        "multi_tenant_data_isolation", "legacy_graphql_maintenance"
      )
    end

    it "is never mixed into any tracked concept vocabulary" do
      expect(AiService::SCENARIO_DOMAINS & AiService::RAILS_CONCEPTS).to be_empty
      expect(AiService::SCENARIO_DOMAINS & AiService::JS_CONCEPTS).to be_empty
      expect(AiService::SCENARIO_DOMAINS & AiService::ARCHITECTURE_CONCEPTS).to be_empty
    end
  end

  describe "GAME_AND_ANIMATION_SCENARIO_DOMAINS" do
    let(:vocabularies) do
      [ AiService::RAILS_CONCEPTS, AiService::JS_CONCEPTS, AiService::ARCHITECTURE_CONCEPTS,
        AiService::PLAN_REVIEW_CONCEPTS, AiService::AMBIGUITY_HUNT_CONCEPTS, AiService::PSEUDOCODE_TO_CODE_CONCEPTS ]
    end

    it "is a frozen, non-empty pool disjoint from the general pool and every concept vocabulary" do
      expect(AiService::GAME_AND_ANIMATION_SCENARIO_DOMAINS).to be_frozen
      expect(AiService::GAME_AND_ANIMATION_SCENARIO_DOMAINS).not_to be_empty
      expect(AiService::GAME_AND_ANIMATION_SCENARIO_DOMAINS & AiService::SCENARIO_DOMAINS).to be_empty
      vocabularies.each do |vocabulary|
        expect(AiService::GAME_AND_ANIMATION_SCENARIO_DOMAINS & vocabulary).to be_empty
      end
    end

    # A setting is names and story. One that names the mechanics of games or
    # animation hands the section a domain fact the engineer has to already
    # know — the frame-rate velocity that failed the first trial. The
    # criterion is held here so the pool cannot drift past it quietly.
    it "names systems to build, never game or animation internals" do
      internals = %w[frame physics render shader collision netcode tick velocity]

      AiService::GAME_AND_ANIMATION_SCENARIO_DOMAINS.each do |domain|
        expect(domain.split("_") & internals).to be_empty, "#{domain} names an internal"
      end
    end

    it "is rolled under exactly the flavors DailyPlan weights" do
      expect(AiService::SCENARIO_POOLS.keys).to match_array(DailyPlan::SCENARIO_FLAVOR_WEIGHTS.keys)
      expect(AiService::SCENARIO_POOLS.dig(:general, :domains)).to equal(AiService::SCENARIO_DOMAINS)
      expect(AiService::SCENARIO_POOLS.dig(:game_and_animation, :domains)).to equal(AiService::GAME_AND_ANIMATION_SCENARIO_DOMAINS)
    end
  end

  describe "#build_concept_reference_prompt (architecture)" do
    it "frames code_example as language-agnostic pseudocode for the architecture config" do
      config = service.send(:config_for, "architecture")
      prompt = service.send(:build_concept_reference_prompt, "service_boundaries", config)
      expect(prompt).to include("software architecture")
      expect(prompt.downcase).to include("pseudocode")
    end

    it "still frames code_example as annotated language code for a normal language config" do
      config = service.send(:config_for, "ruby_rails")
      prompt = service.send(:build_concept_reference_prompt, "n_plus_one", config)
      expect(prompt).to include("annotated Ruby/Rails code")
    end

    # "When to reach for it" is the right lens for a remedy and nonsense for a
    # smell: nothing should ever tell an engineer when to choose a god object.
    it "reframes senior_lens for a code smell, which is never a thing to reach for" do
      config = service.send(:config_for, "ruby_rails")
      prompt = service.send(:build_concept_reference_prompt, "god_object", config)

      expect(prompt).to include("how to catch it early")
      expect(prompt).not_to include("when to reach for it")
    end

    # A shallow module is the same kind of thing as a god object: a shape you
    # find, never one you choose. The reference is generated once and cached
    # forever (GenerateConceptReferenceJob), so the wrong lens is not
    # self-correcting.
    it "reframes senior_lens for a module-design shape, which is never a thing to reach for" do
      config = service.send(:config_for, "ruby_rails")

      AiService::MODULE_DESIGN_CONCEPTS.each do |concept|
        prompt = service.send(:build_concept_reference_prompt, concept, config)

        expect(prompt).to include("how to catch it early"), "#{concept} got the remedy lens"
        expect(prompt).not_to include("when to reach for it")
      end
    end

    # The design principles are the counter-case, and why this stays a
    # membership test rather than "anything in a named group": open_closed IS
    # something to reach for.
    it "keeps the remedy framing for a design principle" do
      config = service.send(:config_for, "ruby_rails")
      prompt = service.send(:build_concept_reference_prompt, "open_closed", config)

      expect(prompt).to include("when to reach for it")
    end

    # cognitive_load and unknown_unknowns are costs a design imposes, not
    # techniques — "when to reach for unknown unknowns" is not a sentence. They
    # reach this method through the architecture pseudo-language, so the lens
    # has to follow the concept rather than the vocabulary it came from.
    it "reframes senior_lens for an architecture-level cause of complexity" do
      config = service.send(:config_for, "architecture")

      AiService::COMPLEXITY_CAUSE_CONCEPTS.each do |concept|
        prompt = service.send(:build_concept_reference_prompt, concept, config)

        expect(prompt).to include("how to catch it early"), "#{concept} got the remedy lens"
        expect(prompt).not_to include("when to reach for it")
      end
    end

    it "keeps the remedy framing for an architecture concept that names a decision" do
      config = service.send(:config_for, "architecture")
      prompt = service.send(:build_concept_reference_prompt, "caching_strategy", config)

      expect(prompt).to include("when to reach for it")
    end

    it "keeps the remedy framing for a concept that names a technique" do
      config = service.send(:config_for, "javascript")
      prompt = service.send(:build_concept_reference_prompt, "state_lifting", config)

      expect(prompt).to include("when to reach for it")
    end
  end

  # guide_worked_example asks for a contrastive PAIR, and which kind of
  # contrast is a property of the concept rather than of the vocabulary it
  # arrived in: ARCHITECTURE_CONCEPTS carries two anti-shapes and
  # DATA_MODELING_CONCEPTS carries one genuine tradeoff, so a group-level
  # branch would frame both wrong. Generated once and cached forever, like the
  # senior_lens framing above, so neither mistake self-corrects.
  describe "#build_concept_reference_prompt (worked-example contrast)" do
    it "asks a defect-shaped concept for a failure-mode/corrected pair of the same scenario" do
      config = service.send(:config_for, "ruby_rails")
      prompt = service.send(:build_concept_reference_prompt, "n_plus_one", config)

      expect(prompt).to include("two short")
      expect(prompt).to include("failure mode")
      expect(prompt).to include("corrected version")
    end

    it "requires the pair to be stated as a mechanism rather than an association" do
      config = service.send(:config_for, "ruby_rails")
      prompt = service.send(:build_concept_reference_prompt, "shallow_module", config)

      expect(prompt).to include("X causes Y")
      expect(prompt).to include("never merely that they are associated")
    end

    # Both options are legitimate, so calling either one "corrected" would
    # misrepresent a real decision as having one right answer.
    it "asks a tradeoff-shaped concept for two legitimate options, neither corrected" do
      config = service.send(:config_for, "architecture")
      prompt = service.send(:build_concept_reference_prompt, "caching_strategy", config)

      expect(prompt).to include("NEITHER is the corrected version")
      expect(prompt).not_to include("failure mode")
    end

    it "keeps the defect framing for an architecture concept that names a cause of complexity" do
      config = service.send(:config_for, "architecture")

      AiService::COMPLEXITY_CAUSE_CONCEPTS.each do |concept|
        prompt = service.send(:build_concept_reference_prompt, concept, config)

        expect(prompt).to include("corrected version"), "#{concept} got the tradeoff contrast"
        expect(prompt).not_to include("NEITHER is the corrected version")
      end
    end

    # Reached through a language config rather than the architecture one: a
    # tradeoff-shaped concept keeps its contrast wherever it is hosted.
    it "gives a tradeoff-shaped data-modeling concept the tradeoff contrast in both languages" do
      %w[ruby_rails javascript].each do |language|
        config = service.send(:config_for, language)
        prompt = service.send(:build_concept_reference_prompt, "denormalization_tradeoffs", config)

        expect(prompt).to include("NEITHER is the corrected version"), "#{language} got the defect contrast"
      end
    end

    it "keeps the defect contrast for the data-modeling concepts that name a flaw" do
      config = service.send(:config_for, "ruby_rails")

      (AiService::DATA_MODELING_CONCEPTS - AiService::TRADEOFF_CONCEPTS).each do |concept|
        prompt = service.send(:build_concept_reference_prompt, concept, config)

        expect(prompt).to include("corrected version"), "#{concept} got the tradeoff contrast"
      end
    end

    it "asks for the pair in pseudocode on a language-agnostic config and in real code otherwise" do
      agnostic = service.send(:build_concept_reference_prompt, "service_boundaries", service.send(:config_for, "architecture"))
      language = service.send(:build_concept_reference_prompt, "n_plus_one", service.send(:config_for, "ruby_rails"))

      expect(agnostic).to include("two short pseudocode fragments")
      expect(language).to include("two short Ruby/Rails fragments")
    end

    # An uncapped field drifts into the essay the guide exists not to be.
    it "still states a bound on the worked example's length" do
      config = service.send(:config_for, "ruby_rails")
      prompt = service.send(:build_concept_reference_prompt, "n_plus_one", config)

      expect(prompt).to include("At most the two fragments plus four sentences of prose")
    end
  end

  describe "TRADEOFF_CONCEPTS" do
    it "excludes the architecture concepts that name a cause of complexity rather than a decision" do
      expect(AiService::TRADEOFF_CONCEPTS & AiService::COMPLEXITY_CAUSE_CONCEPTS).to be_empty
    end

    # The whole point of the constant: shape follows the concept, so a group
    # can be split across both contrasts.
    it "is disjoint from every anti-shape concept" do
      expect(AiService::TRADEOFF_CONCEPTS & AiService::ANTI_SHAPE_CONCEPTS).to be_empty
    end

    it "names only concepts that exist in a tracked vocabulary" do
      tracked = AiService::RAILS_CONCEPTS + AiService::JS_CONCEPTS + AiService::ARCHITECTURE_CONCEPTS
      expect(AiService::TRADEOFF_CONCEPTS - tracked).to be_empty
    end

    # The constant is written out rather than derived from ARCHITECTURE_CONCEPTS
    # so a concept added there cannot inherit the tradeoff framing by accident.
    # This is what makes that deliberate: growing the vocabulary fails here
    # until the new concept is either listed above as having two defensible
    # sides, or named below as one to catch rather than choose between. A
    # reference is generated once and cached forever, so an unconsidered
    # framing does not self-correct.
    it "holds every architecture concept to a deliberate classification" do
      unclassified =
        AiService::ARCHITECTURE_CONCEPTS - AiService::TRADEOFF_CONCEPTS - AiService::COMPLEXITY_CAUSE_CONCEPTS

      expect(unclassified).to be_empty
    end
  end

  describe "LANGUAGE_CONFIG for the fourth-slot pseudo-language buckets" do
    it "resolves plan_review and ambiguity_hunt via config_for, like architecture" do
      plan_review_config    = service.send(:config_for, "plan_review")
      ambiguity_hunt_config = service.send(:config_for, "ambiguity_hunt")

      expect(plan_review_config[:concepts]).to eq(AiService::PLAN_REVIEW_CONCEPTS)
      expect(ambiguity_hunt_config[:concepts]).to eq(AiService::AMBIGUITY_HUNT_CONCEPTS)
    end

    it "frames code_example as language-agnostic pseudocode for both fourth-slot configs" do
      plan_review_prompt = service.send(:build_concept_reference_prompt, "scope_creep",
                                        service.send(:config_for, "plan_review"))
      ambiguity_prompt    = service.send(:build_concept_reference_prompt, "missing_success_criteria",
                                        service.send(:config_for, "ambiguity_hunt"))

      expect(plan_review_prompt.downcase).to include("pseudocode")
      expect(ambiguity_prompt.downcase).to include("pseudocode")
    end

    it "generates a real concept reference for plan_review and ambiguity_hunt (the job path this unblocks)" do
      valid_json = {
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "l"
      }.to_json
      service = double_class.new(canned_text: valid_json)

      plan_review_reference    = service.generate_concept_reference(user, "scope_creep", "plan_review")
      ambiguity_hunt_reference = service.generate_concept_reference(user, "missing_success_criteria", "ambiguity_hunt")

      expect(plan_review_reference).to include("tagline", "explanation", "code_example", "senior_lens")
      expect(ambiguity_hunt_reference).to include("tagline", "explanation", "code_example", "senior_lens")
    end
  end

  describe "#build_exercise_prompt history text" do
    it "reads the section denominator per historical day rather than assuming 3" do
      history = [ { date: "2026-08-01", concepts: {}, scenarios: [], sections_answered: 2,
                    sections_total: 4, self_ratings: {}, ai_ratings: {}, feedback: nil } ]
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", history: history)
      expect(prompt).to include("2/4 answered")
    end
  end

  describe "#build_exercise_prompt" do
    it "instructs that teaching notes hint without giving the answer" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("teaching_note")
      expect(prompt.downcase).to include("never the full answer")
    end

    # The label bound is enforced by ExerciseSection.normalize_scaffold, which
    # truncates rather than rejects, so a kind the rule leaves out has its
    # labels cut mid-word (issue #164). The scope has to come from the registry.
    it "states the answer_scaffold rule for every kind that scaffolds, and no other" do
      prompt     = service.send(:build_exercise_prompt, user)
      rule       = prompt.lines.find { |line| line.include?("- answer_scaffold (") }
      scope      = rule[/answer_scaffold \(([^)]*) only\)/, 1]
      scaffolded = ExerciseSection.all.select(&:scaffolded?).map(&:key)

      expect(scaffolded).to include("plan_review")
      expect(scope.scan(/\w+/)).to match_array(scaffolded + [ "and" ])
    end

    it "instructs that pattern's question must be self-contained, with no code reference" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(
        "\"question\": \"string — conceptual question to answer. Must be fully self-contained: never reference a code snippet, example, or \\\"the code below\\\" — none is shown for this section.\""
      )
    end

    it "asks for the language's test code, in its test framework, in the code_review guidance on a test-file day" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", code_review_mode: :test_file)
      expect(prompt).to include(
        "The code_review snippet must be an RSpec-style Ruby/Rails test file — a realistic test file exhibiting one real test smell"
      )
    end

    it "asks for JavaScript/React test code, in its test framework, in the code_review guidance on a test-file day" do
      prompt = service.send(:build_exercise_prompt, user, "javascript", code_review_mode: :test_file)
      expect(prompt).to include(
        "The code_review snippet must be a Jest/Vitest-style JavaScript/React test file — a realistic test file exhibiting one real test smell"
      )
    end

    it "asks for the day's schema artifact in the code_review guidance on a schema-review day" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", code_review_mode: :schema_review)
      expect(prompt).to include("The code_review snippet must be a Rails migration")
      expect(prompt).to include("one planted data-modeling flaw")
    end

    describe "grounded in Code Gym's own source" do
      it "replaces the mode's toy line with the excerpt's own instruction" do
        excerpt = RealSource::APPLICATION_CODE.first
        prompt  = service.send(:build_exercise_prompt, user, "ruby_rails",
                               code_review_mode: :application_code, code_review_source: excerpt)

        expect(prompt).to include("MODIFIED COPY of this real method")
        expect(prompt).to include(excerpt.id)
        expect(prompt).to include("The scenario field must be exactly")
        expect(prompt).not_to include("must be realistic Ruby/Rails code")
      end

      it "hands a schema_review day the real migration as reference, not as the snippet" do
        excerpt = RealSource::SCHEMA_REVIEW.first
        prompt  = service.send(:build_exercise_prompt, user, "ruby_rails",
                               code_review_mode: :schema_review, code_review_source: excerpt)

        expect(prompt).to include("MODELLED ON this real one")
        expect(prompt).to include("create_table :push_subscriptions")
        expect(prompt).not_to include("The code_review snippet must be a Rails migration")
      end

      # The fourth additive kwarg after cache_system:, max_tokens: and
      # history: — a toy day must read exactly as it did before the grounded
      # path existed.
      it "leaves a toy day's prompt untouched" do
        prompt = service.send(:build_exercise_prompt, user, "ruby_rails", code_review_mode: :application_code)

        expect(prompt).to include("must be realistic Ruby/Rails code")
        expect(prompt).not_to include("Code Gym's own source")
        expect(prompt).not_to include("These source-specific instructions take precedence")
      end

      # Regression for #171: the day's scenario-flavor line and the grounded
      # excerpt's own instruction both land in the same prompt, and the
      # excerpt's instruction is the one place that tells the model the
      # flavor doesn't apply to it. Without that line a game_and_animation day described a real
      # Code Gym table as serving game players.
      it "tells a grounded schema-review section to ignore the day's scenario flavor" do
        excerpt = RealSource::SCHEMA_REVIEW.first
        prompt  = service.send(:build_exercise_prompt, user, "ruby_rails",
                               code_review_mode: :schema_review, code_review_source: excerpt,
                               scenario_flavor: :game_and_animation)

        expect(prompt).to include("platformer save state system")
        expect(prompt).to include("business-domain settings suggested for each section do not apply to this one")
        expect(prompt).to include("never a game or other fictional domain")
      end

      { application_code: "memoization", schema_review: "missing_index" }.each do |mode, concept|
        AiService::SCENARIO_POOLS.each_key do |flavor|
          context "#{mode} with #{flavor} flavor" do
            let(:excerpt) { RealSource.pool(mode).first }

            before do
              exercise = user.daily_exercises.create!(
                date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                problem_set: { "code_review" => { "scenario" => excerpt.scenario, "source" => excerpt.id } }
              )
              user.daily_responses.create!(
                daily_exercise: exercise, date: exercise.date, answers: { "code_review" => "x" * 20 }
              )
            end

            it "lets a repeated excerpt keep its setting and names despite the variety rule" do
              prompt = service.send(:build_exercise_prompt, user, "ruby_rails",
                                    code_review_mode: mode, code_review_source: excerpt, scenario_flavor: flavor)

              expect(prompt).to include("framings: #{excerpt.scenario}")
              expect(prompt).to include('do not reuse the class/method names or narrative framing shown in the "framings:"')
              expect(prompt).to include(
                "These source-specific instructions take precedence over the general variety, mastery-loop, " \
                "and retention requests for new domains, names, or framing"
              )
              expect(prompt).to include("Keep the required source names and setting even if this excerpt appears in prior framings")
              expect(prompt).to include("all other sections still follow the general freshness rules")
            end

            it "keeps grounded retention eligible with a fresh flaw and full difficulty" do
              due = user.concept_masteries.create!(
                concept: concept, language: "ruby_rails", tier: :standard,
                mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 2
              )
              prompt = service.send(:build_exercise_prompt, user, "ruby_rails",
                                    code_review_mode: mode, code_review_source: excerpt, scenario_flavor: flavor,
                                    reinforcement: [], due_checks: [ due ])

              expect(prompt).to include("Retention checks due today: #{concept} (code_review, pattern, or challenge)")
              expect(prompt).to include("new business domain, new class and method names")
              expect(prompt).to include("A retention check may use this excerpt")
              expect(prompt).to include("make the planted flaw a fresh application of the chosen concept")
              expect(prompt).to include("This exception changes neither concept selection nor difficulty")
              expect(prompt).to include("Pitch these at FULL difficulty")
            end
          end
        end
      end
    end

    it "asks for realistic application code by default" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails")
      expect(prompt).to include("The code_review snippet must be realistic Ruby/Rails code — not toy examples.")
    end

    # pattern and the rotating third keep the data-modeling concepts in their
    # vocabulary on every day, so the model can draw one when no schema
    # artifact is on offer. This line is what keeps that from being read as
    # license to write a second schema review into a section that isn't one.
    it "tells the model to express a data-modeling concept in the host section's own idiom" do
      prompt = service.send(:build_exercise_prompt, user, "javascript")
      expect(prompt).to include("may be tagged on any section")
      expect(prompt).to include("Only a schema-review code_review presents a schema artifact to review")
      expect(prompt).to include("not for a migration to review")
    end

    # Named from the constant, not retyped: a concept added to the vocabulary
    # without appearing here would be one the model has no idiom rule for.
    it "names every data-modeling concept in that line" do
      prompt = service.send(:build_exercise_prompt, user, "javascript")
      expect(prompt).to include(
        "The data-modeling concepts (#{AiService::DATA_MODELING_CONCEPTS.join(', ')}) may be tagged on any section"
      )
    end

    # parsons_problem withholds this group, so a blanket "any section" would
    # contradict that section's own vocabulary line in the same prompt — and
    # ingest validates against the FULL vocabulary, so a model resolving the
    # conflict the wrong way produces a parsons problem tagged wrong_cardinality
    # that nothing downstream rejects.
    it "defers to each section's own vocabulary rather than claiming every section" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :parsons_problem)

      expect(prompt).to include("may be tagged on any section whose own vocabulary list above includes them")
      expect(prompt).not_to include("may be tagged on any section.")
    end

    # It applies to the day's other sections regardless of what code_review is
    # doing — on a schema-review day the sentence is what tells the model the
    # other sections are NOT also schema reviews.
    it "states the idiom rule on a schema-review day too" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", code_review_mode: :schema_review)
      expect(prompt).to include("Only a schema-review code_review presents a schema artifact to review")
    end

    # Everything this vocabulary claims about grading rests on this paragraph:
    # the generic review rubric has no `missed` array to fill unless the
    # section still contains one findable issue.
    it "tells the model a meta-skill concept frames a findable issue rather than replacing it" do
      prompt = service.send(:build_exercise_prompt, user)

      expect(prompt).to include("reading_for_intent, spotting_unstated_assumptions, separating_symptom_from_cause")
      expect(prompt).to include("must still contain exactly one specific, findable issue")
      expect(prompt).to include("never asks an open question about the code's purpose")
    end

    # pattern renders no snippet, so the concept has to be expressed against
    # the described design there — the one weak host cell, handled by this line
    # rather than by a per-concept exclusion.
    it "says how to express the concept where no code is shown" do
      expect(service.send(:build_exercise_prompt, user)).to include("Where no code is shown (pattern)")
    end

    # challenge is a third host for a meta-skill concept, graded by the same
    # generic rubric as code_review and pattern — this is its worked example.
    it "gives a worked example for a meta-skill concept hosted by challenge" do
      prompt = service.send(:build_exercise_prompt, user)

      expect(prompt).to include("A challenge tagged separating_symptom_from_cause")
      expect(prompt).to include("never asks for an essay about how to debug")
    end

    it "embeds per-session concepts with per-section self and AI ratings" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            section_ratings: { "code_review" => "too_hard" },
                            concept_tags: { "code_review" => "n_plus_one" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))
      expect(prompt).to include("Mastery loop")
      expect(prompt).to include("code_review→n_plus_one (self: too_hard, ai: unreviewed)")
      expect(prompt).to include("Concepts needing reinforcement right now: n_plus_one (standard)")
    end

    it "shows the AI's per-section rating alongside the self rating when reviewed" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            section_ratings: { "code_review" => "right_level" },
                            concept_tags: { "code_review" => "n_plus_one" },
                            ai_review: { "code_review" => { "rating" => "developing" } })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("code_review→n_plus_one (self: right_level, ai: developing)")
    end

    it "labels a skipped section's history line 'skipped' rather than 'unreviewed'" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {}, "pattern" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20, "pattern" => "" },
                            section_ratings: { "code_review" => "right_level" },
                            concept_tags: { "code_review" => "n_plus_one", "pattern" => "memoization" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("code_review→n_plus_one (self: right_level, ai: unreviewed)")
      expect(prompt).to include("pattern→memoization (self: unrated, ai: skipped)")
    end

    it "reports no concepts needing reinforcement when history is empty" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("Concepts needing reinforcement right now: none")
    end

    it "lists reinforcement concepts with their tier and omits paused ones" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 },
                            section_ratings: { "code_review" => "too_hard" },
                            concept_tags: { "code_review" => "n_plus_one" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("Concepts needing reinforcement right now: n_plus_one (standard)")
    end

    it "includes reduced-tier generation guidance and the tiered mastery-loop instruction" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("annotation includes `reduced`") # the easing rule, drilled form included
      expect(prompt).to include("exits reinforcement only on full mastery")
    end

    it "uses the JS/React vocabulary and JavaScript/React labeling when language is javascript" do
      prompt = service.send(:build_exercise_prompt, user, "javascript")
      expect(prompt).to include(AiService::JS_CONCEPTS.join(", "))
      expect(prompt).to include("JavaScript/React code")
      expect(prompt).not_to include(AiService::RAILS_CONCEPTS.join(", "))
    end

    it "defaults to ruby_rails vocabulary when no language is given" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))
    end

    it "instructs varying the concrete business-domain scenario across sessions" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt.downcase).to include("business-domain scenario")
    end

    # What each kind does with its vocabulary is specified at the kind's own
    # interface. This asserts the half only AiService can get wrong: handing a
    # rolled kind the vocabulary its concepts are later validated against.
    # Both sides call ProblemSetIngest.vocabulary_for, so they cannot drift.
    it "hands each rolled kind the vocabulary ingest will hold it to" do
      %i[architecture security_review challenge parsons_problem].each do |third|
        prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: third)
        expect(prompt).to include(ProblemSetIngest.vocabulary_for(third.to_s, "ruby_rails").join(", "))
      end
    end

    it "includes recent problem framings pulled from the stored problem_set" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current - 1, generated_at: Time.current,
        problem_set: {
          "code_review" => { "scenario" => "inventory restocking" },
          "pattern"     => { "scenario" => "invoice totals" },
          "challenge"   => { "scenario" => "route planner" }
        }
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1,
                            answers: { "code_review" => "x" * 20 })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("framings:")
      expect(prompt).to include("inventory restocking")
    end

    it "includes TypeScript-syntax guidance keyed off the TS-flavored concepts when language is javascript" do
      prompt = service.send(:build_exercise_prompt, user, "javascript")
      expect(prompt).to include("TypeScript syntax")
      expect(prompt).to include(AiService::TYPESCRIPT_FLAVORED_CONCEPTS.join(", "))
    end

    it "omits TypeScript-syntax guidance for ruby_rails" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails")
      expect(prompt).not_to include("TypeScript syntax")
    end

    it "prefers drawing scenarios from SCENARIO_DOMAINS, with legacy GraphQL framed as rare and concept-free" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("background job processing")
      expect(prompt).to include("activerecord query construction")
      expect(prompt.downcase).to include("legacy graphql")
      expect(prompt).to match(/1 in every 8-10/)
      expect(prompt.downcase).to include("never as the tagged concept")
    end

    it "instructs adapting a scenario flavor to the day's stack, for either language" do
      %w[ruby_rails javascript].each do |language|
        prompt = service.send(:build_exercise_prompt, user, language)
        expect(prompt.downcase).to include("adapt any flavor to fit the day's stack")
      end
    end

    describe "scenario flavor" do
      # The fifth additive kwarg after cache_system:, max_tokens:, history: and
      # code_review_source:. The default is the general pool, and the
      # characterization suite holds every snapshot byte-identical under it;
      # this pins the one line that method rewrote.
      it "renders the general pool exactly as before when no flavor is given" do
        prompt = service.send(:build_exercise_prompt, user)

        expect(prompt).to include(
          "- Prefer drawing each section's business-domain scenario from real, job-adjacent flavors like: " \
          "background job processing, api versioning and deprecation, activerecord query construction, " \
          "component state management, data export and reporting, webhook delivery, rate limiting, " \
          "multi tenant data isolation (adapt any flavor to fit the day's stack — e.g. a Rails day's " \
          "\"component state management\" becomes a service/controller state concern instead). " \
          "Use a legacy GraphQL maintenance scenario"
        )
        expect(prompt).not_to include("platformer save state system")
        expect(prompt).not_to include("names and story only")
      end

      it "offers the game and animation pool, with the no-internals rule, on a game_and_animation day" do
        prompt = service.send(:build_exercise_prompt, user, "ruby_rails", scenario_flavor: :game_and_animation)

        AiService::GAME_AND_ANIMATION_SCENARIO_DOMAINS.each do |domain|
          expect(prompt).to include(domain.tr("_", " "))
        end
        expect(prompt).to include("game-development and animation-tooling settings like:")
        expect(prompt.downcase).to include("adapt any flavor to fit the day's stack")
        expect(prompt).to include("The setting supplies names and story only")
        expect(prompt).to include("never require knowing how games or animation work inside")
        expect(prompt).not_to include("background job processing")
      end

      # The one kind that opts out. The characterization suite renders only the
      # default flavor, so the flavor that could reach this schema is checked
      # here: the day's line offers the game pool and the fragment still turns
      # it down.
      it "leaves ambiguity_hunt's own Code Gym framing in place on a game_and_animation day" do
        prompt = service.send(:build_exercise_prompt, user, "ruby_rails",
                              fourth: :ambiguity_hunt, scenario_flavor: :game_and_animation)

        expect(prompt).to include("game-development and animation-tooling settings like:")
        expect(prompt).to include("drawn from Code Gym-style feature requests (a daily-practice app's own features) " \
                                  "and NOT from the scenario flavors listed above")
      end

      it "keeps the legacy GraphQL clause rare and concept-free under either flavor" do
        AiService::SCENARIO_POOLS.each_key do |flavor|
          prompt = service.send(:build_exercise_prompt, user, "ruby_rails", scenario_flavor: flavor)

          expect(prompt).to match(/1 in every 8-10/)
          expect(prompt.downcase).to include("never as the tagged concept")
          expect(prompt).not_to include("legacy graphql maintenance,")
        end
      end

      it "refuses a flavor with no pool rather than rendering an empty list" do
        expect { service.send(:build_exercise_prompt, user, "ruby_rails", scenario_flavor: :nope) }
          .to raise_error(KeyError)
      end
    end
  end

  describe "retention prompt block" do
    it "labels retention concepts separately and demands a fresh scenario at full difficulty" do
      cm = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current - 2)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge,
                            reinforcement: [], due_checks: [ cm ])

      # Asserts the exact rendered line, not merely that "memoization" appears
      # anywhere — memoization is also in RAILS_CONCEPTS and printed in every
      # ruby_rails prompt's vocabulary bullet, so a looser assertion would pass
      # even if due_checks were ignored entirely.
      expect(prompt).to include("Retention checks due today: memoization (code_review, pattern, or challenge)")
      expect(prompt).to match(/retention check/i)
      expect(prompt).to match(/fresh/i)
      expect(prompt).to match(/full difficulty|do not (ease|simplify)/i)
    end

    it "omits the retention block entirely when nothing is due" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge,
                            reinforcement: [], due_checks: [])
      expect(prompt).not_to match(/retention check/i)
    end

    it "annotates a language-bucket concept's legal sections for the architecture third" do
      cm = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current - 2)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :architecture,
                            reinforcement: [], due_checks: [ cm ])

      expect(prompt).to include("Retention checks due today: memoization (code_review or pattern)")
    end

    it "annotates a language-bucket concept as code_review/pattern-only for the security_review third when the concept isn't a security concept" do
      cm = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current - 2)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :security_review,
                            reinforcement: [], due_checks: [ cm ])

      expect(prompt).to include("Retention checks due today: memoization (code_review or pattern)")
    end

    it "annotates a security concept as legal in security_review too" do
      cm = user.concept_masteries.create!(concept: "sql_injection_prevention", language: "ruby_rails", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current - 2)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :security_review,
                            reinforcement: [], due_checks: [ cm ])

      expect(prompt).to include("Retention checks due today: sql_injection_prevention (code_review, pattern, or security_review)")
    end

    it "annotates an architecture-bucket concept as architecture-section-only" do
      cm = user.concept_masteries.create!(concept: "service_boundaries", language: "architecture", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current - 2)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :architecture,
                            reinforcement: [], due_checks: [ cm ])

      expect(prompt).to include("Retention checks due today: service_boundaries (architecture)")
    end

    # day_language defaults to the concept's own bucket, which is correct for
    # every language-bucket concept (its bucket IS the day's language); an
    # architecture-bucket concept's bucket is the pseudo-language
    # "architecture" instead, so those call sites pass the day's real
    # language explicitly.
    def annotation(concept, language:, third:, mode:, day_language: language)
      cm = ConceptMastery.new(user: user, concept: concept, language: language,
                              tier: :standard, next_retention_check_on: Date.current,
                              retention_interval_days: 7)
      kinds = ExerciseSection.for_plan(third: third, fourth: nil)
      service.send(:annotate_retention_concept, cm, kinds, day_language, mode)
    end

    it "offers code_review for a data-modeling concept only on a schema-review day" do
      expect(annotation("missing_index", language: "ruby_rails", third: :challenge, mode: :schema_review))
        .to eq("missing_index (code_review, pattern, or challenge)")
      expect(annotation("missing_index", language: "ruby_rails", third: :challenge, mode: :application_code))
        .to eq("missing_index (pattern or challenge)")
    end

    it "withholds code_review from an ordinary concept on a schema-review day" do
      expect(annotation("n_plus_one", language: "ruby_rails", third: :challenge, mode: :schema_review))
        .to eq("n_plus_one (pattern or challenge)")
    end

    it "is unchanged for an ordinary concept on a non-schema day" do
      expect(annotation("n_plus_one", language: "ruby_rails", third: :challenge, mode: :application_code))
        .to eq("n_plus_one (code_review, pattern, or challenge)")
      expect(annotation("n_plus_one", language: "ruby_rails", third: :architecture, mode: :application_code))
        .to eq("n_plus_one (code_review or pattern)")
      expect(annotation("memoization", language: "ruby_rails", third: :security_review, mode: :application_code))
        .to eq("memoization (code_review or pattern)")
      expect(annotation("sql_injection_prevention", language: "ruby_rails", third: :security_review, mode: :application_code))
        .to eq("sql_injection_prevention (code_review, pattern, or security_review)")
    end

    it "still routes an architecture-bucket concept to its own section" do
      expect(annotation("service_boundaries", language: "architecture", third: :architecture, mode: :application_code,
                        day_language: "ruby_rails"))
        .to eq("service_boundaries (architecture)")
    end

    # The drift this derivation closes, made reachable: give a fixed kind an
    # exclusion and the annotation must stop naming it. Nothing excludes
    # code_review or pattern today, so the only way to prove hosting is derived
    # rather than restated is to introduce an exclusion and watch it take
    # effect. A hand-rolled `hosts << "pattern"` cannot honor this.
    it "drops a fixed section once its kind excludes the concept's group" do
      allow(ExerciseSection::Pattern).to receive(:excluded_vocabulary_keys).and_return([ :data_modeling ])

      expect(annotation("missing_index", language: "ruby_rails", third: :challenge, mode: :schema_review))
        .to eq("missing_index (code_review or challenge)")
    end

    it "drops code_review once its kind excludes the concept's group" do
      allow(ExerciseSection::CodeReview).to receive(:excluded_vocabulary_keys).and_return([ :data_modeling ])

      expect(annotation("missing_index", language: "ruby_rails", third: :challenge, mode: :schema_review))
        .to eq("missing_index (pattern or challenge)")
    end

    # Deriving all three lines removed the old unconditional `pattern`, and with
    # it the guarantee that a concept always has somewhere to go. A concept no
    # section can host must not be listed at all: "reading_for_intent ()"
    # followed by "work it into one of those" tells the model to place it in an
    # empty set, and DailyPlan has already spent a retention slot on it.
    it "omits a due concept no section can host rather than annotating it with nothing" do
      allow(ExerciseSection::Pattern).to receive(:excluded_vocabulary_keys).and_return([ :meta_skill ])
      cm = user.concept_masteries.create!(concept: "reading_for_intent", language: "ruby_rails", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current - 2)

      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :parsons_problem,
                            code_review_mode: :schema_review, reinforcement: [], due_checks: [ cm ])

      expect(prompt).not_to include("reading_for_intent ()")
      expect(prompt).not_to match(/retention check/i)
    end

    # The regression the third slot's derivation fixed: parsons_problem
    # excludes the data-modeling group at generation, but the local `case` that
    # once answered this said "yes" anyway, so the annotation offered the
    # engineer a host that would never be asked for it. All three slots now
    # derive through #can_host?, so the same drift cannot return to any of them.
    it "withholds a parsons_problem third for a group that kind excludes" do
      expect(annotation("missing_index", language: "ruby_rails", third: :parsons_problem, mode: :application_code))
        .to eq("missing_index (pattern)")
      expect(annotation("reading_for_intent", language: "ruby_rails", third: :parsons_problem, mode: :application_code))
        .to eq("reading_for_intent (code_review or pattern)")
    end

    it "offers every ordinary host for a meta-skill concept" do
      expect(annotation("reading_for_intent", language: "ruby_rails", third: :challenge, mode: :application_code))
        .to eq("reading_for_intent (code_review, pattern, or challenge)")
      expect(annotation("separating_symptom_from_cause", language: "javascript", third: :challenge, mode: :application_code))
        .to eq("separating_symptom_from_cause (code_review, pattern, or challenge)")
    end

    # A meta-skill concept is an ordinary language-bucket concept as far as
    # code_review's mode narrowing goes: schema-review days offer only the
    # data-modeling group, so code_review drops off the host list.
    it "withholds code_review from a meta-skill concept on a schema-review day" do
      expect(annotation("spotting_unstated_assumptions", language: "ruby_rails", third: :challenge, mode: :schema_review))
        .to eq("spotting_unstated_assumptions (pattern or challenge)")
    end
  end

  describe "#annotate_retention_concept" do
    let(:concept) do
      ConceptMastery.new(concept: "service_boundaries", language: "architecture",
                         retention_interval_days: 7, next_retention_check_on: Date.current)
    end

    it "annotates an architecture concept to the architecture section when the day has one" do
      kinds = ExerciseSection.for_plan(third: :architecture, fourth: nil)

      expect(service.send(:annotate_retention_concept, concept, kinds, "ruby_rails", :application_code))
        .to include("architecture")
    end

    it "drops an architecture concept on a day with no architecture section" do
      kinds = ExerciseSection.for_plan(third: :challenge, fourth: nil)

      expect(service.send(:annotate_retention_concept, concept, kinds, "ruby_rails", :application_code)).to be_nil
    end
  end

  describe "established prompt block" do
    it "advises minimal scaffolding and full difficulty for concepts with mastery history" do
      cm = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                          mastered_at: 2.months.ago, retention_interval_days: 14,
                                          next_retention_check_on: Date.current + 10)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge,
                            reinforcement: [], due_checks: [], established: [ cm ])

      expect(prompt).to include(
        "Established concepts (well past first mastery — survived a retention check): memoization"
      )
      expect(prompt).to match(/keep that section's teaching_note minimal/i)
      expect(prompt).to match(/full difficulty/i)
      expect(prompt).to match(/does not force you to select/i)
    end

    it "omits the established block entirely when nothing qualifies" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge,
                            reinforcement: [], due_checks: [], established: [])
      expect(prompt).not_to match(/well past first mastery/i)
    end

    it "lists multiple established concepts comma-separated" do
      cm1 = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                           mastered_at: 2.months.ago, retention_interval_days: 14,
                                           next_retention_check_on: Date.current + 10)
      cm2 = user.concept_masteries.create!(concept: "scope_chaining", language: "ruby_rails", tier: :standard,
                                           mastered_at: 1.month.ago, retention_interval_days: 28,
                                           next_retention_check_on: Date.current + 20)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge,
                            reinforcement: [], due_checks: [], established: [ cm1, cm2 ])
      expect(prompt).to include("memoization, scope_chaining")
    end
  end

  describe "difficulty targets in the generation prompt" do
    def render(difficulty:, ladders: {}, third: :challenge, fourth: :plan_review, mode: :application_code)
      service.send(:build_exercise_prompt, user, "ruby_rails",
                   third: third, fourth: fourth, code_review_mode: mode,
                   reinforcement: [], due_checks: [], established: [], history: [],
                   difficulty: difficulty, ladders: ladders)
    end

    let(:untargeted) { render(difficulty: KindDifficulty.none) }

    it "renders nothing new for a user with no targets" do
      expect(render(difficulty: KindDifficulty.new(levels: {}, locked: []))).to eq(untargeted)
      expect(untargeted).not_to include("Difficulty targets")
    end

    it "renders nothing new when the targeted kinds are not on today's plan" do
      difficulty = KindDifficulty.new(levels: { "architecture" => "senior", "ambiguity_hunt" => "junior" },
                                      locked: [ "architecture" ])

      expect(render(difficulty: difficulty, ladders: { "senior" => { "n_plus_one" => "rung" } })).to eq(untargeted)
    end

    it "lists one concept once for sections sharing a level" do
      difficulty = KindDifficulty.new(levels: { "code_review" => "senior", "challenge" => "senior" }, locked: [])
      prompt = render(difficulty: difficulty, ladders: { "senior" => { "n_plus_one" => "hidden behind a helper" } })

      expect(prompt).to include("Sections at senior: code_review, challenge")
      expect(prompt.scan("- n_plus_one: hidden behind a helper").size).to eq(1)
      expect(prompt).to include("For a concept not listed, a senior problem is: #{KindDifficulty::LEVEL_DEFINITIONS['senior']}")
    end

    it "falls back to the definition alone when nothing at a level is grounded" do
      difficulty = KindDifficulty.new(levels: { "pattern" => "junior" }, locked: [])

      expect(render(difficulty: difficulty)).to include("A junior problem is: #{KindDifficulty::LEVEL_DEFINITIONS['junior']}")
    end

    it "defines full difficulty for retention checks in targeted sections" do
      difficulty = KindDifficulty.new(levels: { "challenge" => "principal_engineer" }, locked: [])

      expect(render(difficulty: difficulty))
        .to include("A retention check or established concept placed in one of these sections is pitched at that section's level, with no easing.")
    end

    it "names unlocked and locked sections on their own lines" do
      difficulty = KindDifficulty.new(levels: { "code_review" => "senior", "challenge" => "principal_engineer" },
                                      locked: [ "challenge" ])
      prompt = render(difficulty: difficulty)

      expect(prompt).to include("Unlocked (code_review): tier annotations and rating adjustments above still apply")
      expect(prompt).to include("Locked (challenge): for these sections, ignore the `(reduced)` easing rule")
      expect(prompt).to include("including a concept the engineer has never seen")
    end

    it "omits the lock line when nothing is locked, and the unlocked line when everything is" do
      unlocked = render(difficulty: KindDifficulty.new(levels: { "challenge" => "senior" }, locked: []))
      locked   = render(difficulty: KindDifficulty.new(levels: { "challenge" => "senior" }, locked: [ "challenge" ]))

      expect(unlocked).not_to include("Locked (")
      expect(locked).not_to include("Unlocked (")
    end

    # The read-side half of the invariant, end to end: a lock with no level must
    # never reach the prompt.
    it "renders no lock for an orphaned lock written past validation" do
      user.save!
      user.update_columns(locked_section_kinds: [ "challenge" ])

      expect(render(difficulty: KindDifficulty.for(user.reload))).to eq(untargeted)
    end

    describe "#ladders_for" do
      it "loads each targeted kind's rungs for the day's mode and merges them by level" do
        ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                                 ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "p")
        schema_concept = AiService::DATA_MODELING_CONCEPTS.first
        ConceptReference.create!(concept: schema_concept, language: "ruby_rails",
                                 ladder_junior: "j2", ladder_senior: "s2", ladder_principal_engineer: "p2")
        kinds = ExerciseSection.for_plan(third: :challenge, fourth: nil)
        difficulty = KindDifficulty.new(levels: { "code_review" => "senior", "challenge" => "senior" }, locked: [])

        ladders = service.send(:ladders_for, kinds, difficulty, "ruby_rails", :schema_review)

        expect(ladders.keys).to eq([ "senior" ])
        expect(ladders["senior"]).to include("n_plus_one" => "s", schema_concept => "s2")
      end
    end

    describe "MAX_LADDER_GUIDANCE_CHARS" do
      # For each day shape, every level assignment is rendered for real, with
      # every rung at its maximum length, then the largest lock-instruction
      # overhead is added independently across all lock subsets. The
      # largest rendered length wins. Headings, fallback definitions and
      # section-list overhead differ between assignments, so only rendering
      # every one of them (not a proxy over rung payload alone) can find the
      # true maximum. Fails when a vocabulary grows past the budget, so the
      # decision to shorten rungs or change delivery is made on purpose.
      def largest_block_for(language, mode, third, fourth)
        kinds = ExerciseSection.for_plan(pattern: :pattern, third: third, fourth: fourth)
        vocab = kinds.to_h { |kind| [ kind, ProblemSetIngest.selectable_vocabulary_for(kind.key, language, mode: mode) ] }

        KindDifficulty::LEVELS.repeated_permutation(kinds.size).map do |levels|
          placed = kinds.zip(levels)
          difficulty = KindDifficulty.new(levels: placed.to_h { |kind, level| [ kind.key, level ] }, locked: kinds.map(&:key))
          ladders = placed.each_with_object({}) do |(kind, level), acc|
            (acc[level] ||= {}).merge!(vocab[kind].index_with { "x" * AiService::MAX_LADDER_RUNG_LENGTH })
          end

          service.send(:kind_difficulty_guidance, kinds, difficulty, ladders).length
        end.max + lock_subsets(kinds).map { |locked| lock_instruction_length(kinds, locked) }.max -
          lock_instruction_length(kinds, kinds)
      end

      def lock_subsets(kinds)
        (0..kinds.size).flat_map { |count| kinds.combination(count).to_a }
      end

      def lock_instruction_length(kinds, locked)
        [ service.send(:unlocked_difficulty_line, kinds - locked),
          service.send(:locked_difficulty_line, locked) ].compact.sum { |line| line.length + 1 }
      end

      it "holds the largest block any day can render" do
        shapes = DailyExercise::LANGUAGES.product(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys,
                                                  ExerciseSection.thirds.map { |kind| kind.key.to_sym },
                                                  ExerciseSection.fourths.map { |kind| kind.key.to_sym })

        expect(shapes.map { |shape| largest_block_for(*shape) }.max).to be <= AiService::MAX_LADDER_GUIDANCE_CHARS
      end

      it "includes mixed locks that render more instructions than locking every kind" do
        kinds = ExerciseSection.for_plan(pattern: :pattern, third: :challenge, fourth: :pseudocode_to_code)
        levels = { "code_review" => "junior", "pattern" => "senior",
                   "challenge" => "principal_engineer", "pseudocode_to_code" => "junior" }
        ladders = kinds.each_with_object({}) do |kind, acc|
          vocabulary = ProblemSetIngest.selectable_vocabulary_for(kind.key, "javascript", mode: :application_code)
          (acc[levels.fetch(kind.key)] ||= {}).merge!(vocabulary.index_with { "x" * AiService::MAX_LADDER_RUNG_LENGTH })
        end
        difficulty = KindDifficulty.new(levels: levels, locked: [ "code_review" ])
        mixed = service.send(:kind_difficulty_guidance, kinds, difficulty, ladders).length

        expect(largest_block_for("javascript", :application_code, :challenge, :pseudocode_to_code)).to be >= mixed
      end

      it "isolates lock overhead from every level assignment in the rendered block" do
        kinds = ExerciseSection.for_plan(pattern: :pattern, third: :challenge, fourth: :pseudocode_to_code)
        rungs = KindDifficulty::LEVELS.index_with { { "example" => "x" * AiService::MAX_LADDER_RUNG_LENGTH } }

        KindDifficulty::LEVELS.repeated_permutation(kinds.size).each do |levels|
          targets = kinds.map(&:key).zip(levels).to_h
          [ {}, rungs ].each do |ladders|
            all_locked = KindDifficulty.new(levels: targets, locked: targets.keys)
            baseline = service.send(:kind_difficulty_guidance, kinds, all_locked, ladders).length
            lock_subsets(kinds).each do |locked|
              difficulty = KindDifficulty.new(levels: targets, locked: locked.map(&:key))
              actual = service.send(:kind_difficulty_guidance, kinds, difficulty, ladders).length
              expected = baseline + lock_instruction_length(kinds, locked) - lock_instruction_length(kinds, kinds)

              expect(actual).to eq(expected)
            end
          end
        end
      end
    end
  end

  describe "diagram instructions in the generation prompt" do
    # The syntax rules used to live in the architecture-only branch. They now
    # govern code_review and pattern, which are present every single day.
    it "states the Mermaid syntax constraints regardless of which third was rolled" do
      %i[challenge parsons_problem security_review architecture].each do |third|
        prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: third)

        expect(prompt).to include("flowchart TD")
        expect(prompt).to include("Maximum 8 nodes")
        expect(prompt).to match(/empty string/i)
      end
    end

    # The safety property: depicting a problem's shape must not reveal its
    # solution.
    it "forbids diagramming the fix rather than the scenario as written" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge)

      expect(prompt).to match(/never diagram the fix/i)
      expect(prompt).to match(/never annotate a node as the problem/i)
    end

    it "instructs the diagram to show repetition when a loop wraps the flow" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge)

      expect(prompt).to include("repeated invocation that wraps the flow")
      expect(prompt).to include("per-item cardinality")
      expect(prompt).to include("once per customer")
    end

    it "does not force a loop cue on snippets without one" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge)

      expect(prompt).to include("Do not manufacture a loop or cardinality label when the snippet has none")
    end
  end

  # Ingest owns each step and specs them at its own interface; these assert the
  # wiring only AiService can get wrong — that generation runs ingest at all,
  # and that the suggestions it returns get written.
  describe "generation runs the ingest boundary" do
    it "runs on generation, so a bad diagram never reaches a persisted problem set" do
      svc = double_class.new(canned_text: full_problem_set(
        "code_review" => { "question" => "q", "concept" => "n_plus_one", "diagram" => "x" * 5_000 },
        "pattern"     => { "question" => "q", "concept" => "memoization", "diagram" => "flowchart TD\n  A --> B" }
      ).to_json)

      problem_set = svc.generate_exercise(user)

      expect(problem_set["code_review"]).not_to have_key("diagram")
      expect(problem_set["pattern"]["diagram"]).to eq("flowchart TD\n  A --> B")
    end

    it "writes the SuggestedConcept rows ingest reports" do
      svc = double_class.new(canned_text: full_problem_set(
        "code_review" => { "question" => "q", "concept" => "Invented Concept!!" }
      ).to_json)

      expect { svc.generate_exercise(user) }.to change(SuggestedConcept, :count).by(1)
      expect(SuggestedConcept.last.display_name).to eq("Invented Concept!!")
      expect(SuggestedConcept.last.language).to eq("ruby_rails")
    end

    # A lost analytics signal is not a reason to fail someone's morning set.
    it "swallows a recording failure and still returns the problem set" do
      allow(SuggestedConcept).to receive(:record!).and_raise(StandardError, "db down")
      svc = double_class.new(canned_text: full_problem_set(
        "code_review" => { "question" => "q", "concept" => "Invented Concept!!" }
      ).to_json)

      # full_problem_set returns every kind, so the set also trips the
      # unrequested-sections warning. Only the recording failure is asserted.
      allow(Rails.logger).to receive(:warn)
      expect(Rails.logger).to receive(:warn).with(/SuggestedConcept recording failed.*db down/)
      expect(svc.generate_exercise(user)["code_review"]["concept"]).to eq("other")
    end

    # The rescue is per suggestion, not around the loop: one failing name must
    # not discard the signals queued behind it.
    it "keeps recording the remaining suggestions after one of them fails" do
      allow(SuggestedConcept).to receive(:record!).and_call_original
      allow(SuggestedConcept).to receive(:record!)
        .with(hash_including(name: "First Invention!!")).and_raise(StandardError, "db down")

      svc = double_class.new(canned_text: full_problem_set(
        "code_review" => { "question" => "q", "concept" => "First Invention!!" },
        "pattern"     => { "title" => "t", "concept" => "Second Invention!!" }
      ).to_json)

      allow(Rails.logger).to receive(:warn)

      expect { svc.generate_exercise(user) }.to change(SuggestedConcept, :count).by(1)
      expect(SuggestedConcept.last.display_name).to eq("Second Invention!!")
    end

    it "propagates an ingest rejection as a generation failure" do
      svc = double_class.new(canned_text: {
        "code_review"    => { "question" => "q", "concept" => "n_plus_one" },
        "ambiguity_hunt" => { "request" => "vague", "planted_ambiguities" => [] }
      }.to_json)

      expect { svc.generate_exercise(user) }.to raise_error(AiService::InvalidResponseError)
    end

    # The guarantee ingest's purity buys: a rejected set cannot have written a
    # vocabulary suggestion, because the write only happens after ingest returns.
    it "writes no suggestion when ingest rejects the set" do
      svc = double_class.new(canned_text: {
        "code_review"    => { "question" => "q", "concept" => "Invented Concept!!" },
        "ambiguity_hunt" => { "request" => "vague", "planted_ambiguities" => [] }
      }.to_json)

      expect { svc.generate_exercise(user) rescue nil }.not_to change(SuggestedConcept, :count)
    end
  end

  describe "#parse_json_response" do
    it "strips markdown fences before parsing" do
      fenced = "```json\n{\"a\":1}\n```"
      expect(service.send(:parse_json_response, fenced)).to eq("a" => 1)
    end

    it "raises AiService::Error for invalid JSON" do
      expect {
        service.send(:parse_json_response, "not json")
      }.to raise_error(AiService::Error, /invalid JSON/)
    end

    it "raises the more specific InvalidResponseError subclass for invalid JSON" do
      expect {
        service.send(:parse_json_response, "not json")
      }.to raise_error(AiService::InvalidResponseError)
    end

    it "does not leak the raw provider text into the exception message" do
      huge_text = "garbage " * 200
      expect {
        service.send(:parse_json_response, huge_text)
      }.to raise_error(AiService::Error) { |e| expect(e.message).not_to include(huge_text) }
    end

    it "logs a truncated snippet of the raw provider text server-side" do
      huge_text = "x" * 1000
      expect(Rails.logger).to receive(:error) do |msg|
        expect(msg).to include("Invalid JSON from provider")
        expect(msg).to include("truncated, #{huge_text.bytesize} bytes total")
        expect(msg.length).to be < huge_text.length
      end

      expect { service.send(:parse_json_response, huge_text) }.to raise_error(AiService::Error)
    end

    it "scrubs an invalid byte sequence left by truncating mid-character, instead of raising" do
      # A 3-byte UTF-8 character ("€") straddling byte offset RAW_SNIPPET_LIMIT
      # (500) so byteslice cuts it in half, leaving an invalid trailing byte.
      text = ("a" * 499) + "€" + ("b" * 10)

      expect(Rails.logger).to receive(:error) do |msg|
        expect(msg.encoding).to eq(Encoding::UTF_8)
        expect(msg.valid_encoding?).to be true
      end

      expect { service.send(:parse_json_response, text) }.to raise_error(AiService::Error)
    end
  end

  describe "#extract_provider_message" do
    it "returns the provider's error.message when the body is a matching JSON error object" do
      body = {
        "type"  => "error",
        "error" => { "type" => "insufficient_quota", "message" => "Your credit balance is too low to access the Anthropic API." }
      }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("Your credit balance is too low to access the Anthropic API.")
    end

    it "falls back when the body is not JSON" do
      expect(service.send(:extract_provider_message, "not json", fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when the JSON body has no error.message" do
      body = { "type" => "error", "error" => { "type" => "overloaded_error" } }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when error.message is blank" do
      body = { "error" => { "message" => "" } }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when the body is nil instead of raising" do
      expect(service.send(:extract_provider_message, nil, fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when the body is not a String instead of raising" do
      expect(service.send(:extract_provider_message, 123, fallback: "fallback text"))
        .to eq("fallback text")
    end
  end

  describe "#generate_exercise" do
    it "shuffles parsons_problem blocks into a non-identity display_order" do
      set = full_problem_set("parsons_problem" => { "blocks" => %w[a b c d e] })
      svc = double_class.new(canned_text: set.to_json)

      result = svc.generate_exercise(user)

      order = result["parsons_problem"]["display_order"]
      expect(order).to match_array([ 0, 1, 2, 3, 4 ])
      expect(order).not_to eq([ 0, 1, 2, 3, 4 ])
    end

    it "leaves problem sets without a parsons_problem section untouched" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :architecture, fourth: :plan_review)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_call_original
      set = { "code_review" => { "concept" => "n_plus_one" }, "pattern" => {},
              "architecture" => {}, "plan_review" => {} }
      svc = double_class.new(canned_text: set.to_json)

      result = svc.generate_exercise(user)
      expect(result).not_to have_key("parsons_problem")
    end

    it "raises rather than returning a problem set that isn't a JSON object" do
      svc = double_class.new(canned_text: '["not", "a", "problem set"]')

      expect {
        svc.generate_exercise(user)
      }.to raise_error(AiService::InvalidResponseError, /Array instead of a JSON object/)
    end

    it "logs usage and normalizes concepts from the provider's response using the resolved language" do
      set = full_problem_set("code_review" => { "concept" => "bogus" })
      svc = double_class.new(canned_text: set.to_json, input_tokens: 5, output_tokens: 7)

      result = svc.generate_exercise(user)

      expect(result["code_review"]["concept"]).to eq("other")
      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(5)
      expect(usage.tokens_out).to eq(7)
      expect(usage.purpose).to eq("generate_exercise")
    end

    it "normalizes against the JS vocabulary when an explicit javascript language is passed" do
      set = full_problem_set("code_review" => { "concept" => "closures" })
      svc = double_class.new(canned_text: set.to_json)

      result = svc.generate_exercise(user, language: "javascript")

      expect(result["code_review"]["concept"]).to eq("closures")
    end

    it "defaults language to the user's language_for_today when not passed explicitly" do
      user.update!(language: "javascript")
      set = full_problem_set("code_review" => { "concept" => "closures" })
      svc = double_class.new(canned_text: set.to_json)

      result = svc.generate_exercise(user)

      expect(result["code_review"]["concept"]).to eq("closures")
    end

    it "threads the rolled third-section kind into the exercise prompt" do
      set = full_problem_set("code_review" => { "concept" => "n_plus_one" })
      svc = double_class.new(canned_text: set.to_json)
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :architecture, fourth: :plan_review)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_call_original
      expect(svc).to receive(:build_exercise_prompt).with(user, anything, hash_including(third: :architecture)).and_call_original
      svc.generate_exercise(user)
    end

    # Every other retention test stubs concepts_needing_reinforcement, which is
    # exactly what hid the original bug: `slots = [3 - reinforcement.size, 0].max`
    # sized against the FULL reinforcement list (realistically 4-8 concepts for
    # any active user), not the 3 sections an exercise can actually hold, so
    # slots was 0 and a due retention check could never reach the prompt. This
    # builds a realistic reinforcement list from real DailyResponse rows instead.
    # The mastery below must be OVERDUE (past due by its own full interval), not
    # merely due — under the current policy a merely-due check does not reclaim
    # a slot from a full reinforcement list.
    it "still surfaces an overdue retention check when real history fills all three reinforcement slots" do
      # 4 distinct, still-struggling concepts across 4 real submitted days — enough
      # that concepts_needing_reinforcement realistically returns more than 3 entries.
      %w[n_plus_one transaction_safety service_objects scope_chaining].each_with_index do |concept, i|
        date = Date.current - (i + 2)
        exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                         problem_set: { "code_review" => { "concept" => concept } })
        DailyResponse.create!(user: user, daily_exercise: exercise, date: date,
                              answers: { "code_review" => "x" * 20 },
                              section_ratings: { "code_review" => "too_hard" },
                              concept_tags: { "code_review" => concept })
      end
      expect(user.concepts_needing_reinforcement.size).to be > 3

      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 8)

      captured_prompt = nil
      spy_class = Class.new(double_class) do
        define_method(:build_exercise_prompt) do |*args, **kwargs|
          result = super(*args, **kwargs)
          captured_prompt = result
          result
        end
      end
      set = full_problem_set("code_review" => { "concept" => "n_plus_one" })
      svc = spy_class.new(canned_text: set.to_json)
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_call_original

      svc.generate_exercise(user, language: "ruby_rails")

      expect(captured_prompt).to include("Retention checks due today: memoization")
    end

    describe "the overdue-threshold reservation policy" do
      # Real reinforcement history (not a stub of concepts_needing_reinforcement)
      # so slots genuinely computes to 0 before any retention consideration —
      # stubbing the reinforcement list is exactly what hid the original bug.
      def build_reinforcement_history(concepts: %w[n_plus_one transaction_safety service_objects scope_chaining])
        concepts.each_with_index do |concept, i|
          date = Date.current - (i + 2)
          exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                           problem_set: { "code_review" => { "concept" => concept } })
          DailyResponse.create!(user: user, daily_exercise: exercise, date: date,
                                answers: { "code_review" => "x" * 20 },
                                section_ratings: { "code_review" => "too_hard" },
                                concept_tags: { "code_review" => concept })
        end
      end

      def mastery(due_on:, bucket: "ruby_rails", concept: "memoization", interval: 7)
        user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                       mastered_at: 1.month.ago, retention_interval_days: interval,
                                       next_retention_check_on: due_on)
      end

      def capture_prompt_for(third:)
        captured_prompt = nil
        spy_class = Class.new(double_class) do
          define_method(:build_exercise_prompt) do |*args, **kwargs|
            result = super(*args, **kwargs)
            captured_prompt = result
            result
          end
        end
        svc = spy_class.new(canned_text: full_problem_set("code_review" => { "concept" => "n_plus_one" }).to_json)
        allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: third, fourth: :plan_review)
        allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_call_original

        svc.generate_exercise(user, language: "ruby_rails")
        captured_prompt
      end

      it "keeps all 3 reinforcement slots when a check is due but not yet overdue by its own interval" do
        build_reinforcement_history
        expect(user.concepts_needing_reinforcement.size).to be > 3
        mastery(due_on: Date.current - 2) # due (interval 7 means threshold is at -7, not crossed)

        prompt = capture_prompt_for(third: :challenge)

        expect(prompt).not_to match(/Retention checks due today/)
      end

      it "reserves a slot once the check crosses its own interval's overdue threshold" do
        build_reinforcement_history
        mastery(due_on: Date.current - 8) # due_on + interval(7) = -1, past today: crossed

        prompt = capture_prompt_for(third: :challenge)

        expect(prompt).to include("Retention checks due today: memoization")
      end

      it "reads the threshold from RETENTION_OVERDUE_THRESHOLD_MULTIPLIER rather than a hardcoded value" do
        build_reinforcement_history
        mastery(due_on: Date.current - 8) # qualifies at multiplier 1 (8 days > 7-day interval)
        stub_const("ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER", 2)

        prompt = capture_prompt_for(third: :challenge)

        expect(prompt).not_to match(/Retention checks due today/)
      end

      it "does not reserve a slot for an architecture-bucket concept overdue on a challenge day" do
        build_reinforcement_history
        mastery(due_on: Date.current - 8, bucket: "architecture", concept: "service_boundaries")

        prompt = capture_prompt_for(third: :challenge)

        expect(prompt).not_to match(/Retention checks due today/)
      end
    end
  end

  describe "retention instrumentation" do
    def due_mastery
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 2)
    end

    it "logs offered and honored when the model used the due concept" do
      due_mastery
      set = full_problem_set("code_review" => { "concept" => "memoization" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      expect(Rails.logger).to receive(:info).with(/\[retention\].*offered=memoization.*honored=memoization/)
      expect(Rails.logger).to receive(:info).with(/\[difficulty_diagnostics\]/)
      svc.generate_exercise(user, language: "ruby_rails")
    end

    it "logs an empty honored list when the model ignored the due concept" do
      due_mastery
      set = full_problem_set("code_review" => { "concept" => "n_plus_one" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      expect(Rails.logger).to receive(:info).with(/\[retention\].*offered=memoization.*honored=-.*tagged=n_plus_one/)
      expect(Rails.logger).to receive(:info).with(/\[difficulty_diagnostics\]/)
      svc.generate_exercise(user, language: "ruby_rails")
    end

    it "logs nothing when no check is due" do
      set = full_problem_set("code_review" => { "concept" => "n_plus_one" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      expect(Rails.logger).not_to receive(:info).with(/\[retention\]/)
      svc.generate_exercise(user, language: "ruby_rails")
    end

    # The fourth slot's retention offers ride a bucket, not the day's language,
    # and this log line is the only offered-vs-honored evidence there is — an
    # offer that never appears here can be silently ignored forever.
    it "logs the fourth slot's offer under its own bucket" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 2)
      set = full_problem_set("plan_review" => { "concept" => "scope_creep" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_call_original

      logged = []
      allow(Rails.logger).to receive(:info) do |msg|
        logged << msg if msg.is_a?(String) && msg.start_with?("[retention]")
      end

      svc.generate_exercise(user, language: "ruby_rails")

      expect(logged).to include(/bucket=plan_review.*offered=scope_creep.*honored=scope_creep/)
    end
  end

  describe "difficulty diagnostics instrumentation" do
    def diagnostics_payload(svc)
      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end
      svc.generate_exercise(user, language: "ruby_rails")
      JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
    end

    it "logs what was requested and what was delivered on every generation" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      set = full_problem_set("code_review" => { "concept" => "memoization", "title" => "t", "question" => "q" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([ { concept: "n_plus_one", bucket: "ruby_rails", tier: "reduced" } ])

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      svc.generate_exercise(user, language: "ruby_rails")

      expect(logged).not_to be_nil
      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))

      expect(payload["event"]).to eq("generation")
      expect(payload["user_id"]).to eq(user.id)
      expect(payload["date"]).to eq(Date.current.to_s)
      expect(payload["language"]).to eq("ruby_rails")
      expect(payload["requested"]["skill_level"]).to eq(user.skill_level)
      expect(payload["requested"]["reinforcement"]).to eq([ { "concept" => "n_plus_one", "bucket" => "ruby_rails", "tier" => "reduced" } ])
      expect(payload["requested"]).to have_key("due_checks")
      expect(payload["requested"]).to have_key("established")
      expect(payload["requested"]).to have_key("recent_performance")
      expect(payload["requested"]["pattern"]).to eq("pattern")
      expect(payload["requested"]["third"]).to eq("challenge")
      expect(payload["requested"]["fourth"]).to eq("plan_review")
      expect(payload["requested"]["section_count"]).to eq(4)
      # Ingest stamps the rung each presented section was pitched at, so the
      # delivered record carries it; everything else is the set as returned.
      without_stamps = payload["delivered"].transform_values { |section| section.is_a?(Hash) ? section.except("pitched_at", "eased") : section }
      expect(without_stamps).to eq(JSON.parse(set.to_json))
      expect(payload["delivered"]["code_review"]["pitched_at"]).to eq("junior")
    end

    it "includes due retention checks and established concepts by name" do
      # Due: standard tier, next_retention_check_on in the past.
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 2)
      # Established: standard tier, past its initial interval, but not yet
      # due — DailyPlan.established_concepts_for excludes anything due_checks
      # already claimed, so this needs its own, distinct concept.
      user.concept_masteries.create!(concept: "transaction_safety", language: "ruby_rails", tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: 14,
                                     next_retention_check_on: Date.current + 5)
      set = full_problem_set("code_review" => { "concept" => "memoization" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      svc.generate_exercise(user, language: "ruby_rails")

      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload["requested"]["due_checks"]).to eq([ "memoization" ])
      expect(payload["requested"]["established"]).to eq([ "transaction_safety" ])
    end

    # This is the only place a whole problem_set is serialized, so it is the
    # only place the ambiguity hunt's answer key could reach log storage.
    it "redacts the ambiguity hunt's planted answer key from the delivered payload" do
      planted = Array.new(ExerciseSection::AmbiguityHunt::PLANTED_COUNT) { |i| "secret ambiguity #{i}" }
      set = full_problem_set(
        "code_review"    => { "concept" => "n_plus_one" },
        "ambiguity_hunt" => { "concept" => "missing_success_criteria",
                              "request" => "Build us a leaderboard",
                              "planted_ambiguities" => planted }
      )
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      problem_set = svc.generate_exercise(user, language: "ruby_rails")

      expect(logged).not_to include("secret ambiguity")
      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload["delivered"]["ambiguity_hunt"]).not_to have_key("planted_ambiguities")
      expect(payload["delivered"]["ambiguity_hunt"]["request"]).to eq("Build us a leaderboard")
      # Redaction is for the log only — the persisted set still carries the key.
      expect(problem_set["ambiguity_hunt"]["planted_ambiguities"]).to eq(planted)
    end

    # Every other code_review_mode example in this file calls
    # build_exercise_prompt directly, which defaults code_review_mode to
    # :application_code — so none of them would notice if generate_exercise
    # stopped passing plan.code_review_mode through. This is the one example
    # on the real #generate_exercise path: it proves the rolled mode reaches
    # both the prompt the provider receives and the logged payload.
    it "threads the rolled mode into both the prompt and the diagnostics payload" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_return(:schema_review)

      set = full_problem_set("code_review" => { "concept" => "missing_index" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      svc.generate_exercise(user, language: "ruby_rails")

      expect(svc.last_prompt).to include("The code_review snippet must be a Rails migration")

      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload["requested"]["code_review_mode"]).to eq("schema_review")
    end

    # The same reasoning as the example above, for the grounded path: every
    # other real-source example drives build_exercise_prompt or ingest
    # directly, so only this one proves the plan's excerpt reaches all three
    # of the prompt, the stamped set, and the logged payload.
    it "threads a grounded code_review into the prompt, the stamped set, and the diagnostics payload" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_return(:application_code)
      allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:real)
      excerpt = RealSource::APPLICATION_CODE.first

      set = full_problem_set("code_review" => { "concept" => "memoization", "scenario" => "inventory restocking service" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      problem_set = svc.generate_exercise(user, language: "ruby_rails")

      expect(svc.last_prompt).to include("MODIFIED COPY of this real method")
      expect(svc.last_prompt).to include(excerpt.text.strip_heredoc.chomp)
      expect(problem_set["code_review"]["scenario"]).to eq(excerpt.scenario)
      expect(problem_set["code_review"]["source"]).to eq(excerpt.id)

      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload["requested"]["code_review_source"]).to eq(excerpt.id)
    end

    # Rolled in DailyPlan, read by the prompt, recorded here: one example
    # proves the flavor reaches both ends, since every other flavor example
    # drives build_exercise_prompt directly.
    it "threads the day's scenario flavor into the prompt and the diagnostics payload" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::SCENARIO_FLAVOR_WEIGHTS).and_return(:game_and_animation)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])
      svc = double_class.new(canned_text: full_problem_set.to_json)

      payload = diagnostics_payload(svc)

      expect(svc.last_prompt).to include("game-development and animation-tooling settings like:")
      expect(payload["requested"]["scenario_flavor"]).to eq("game_and_animation")
    end

    it "omits difficulty fields when nothing targeted is on the plan" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])
      user.update!(section_kind_levels: { "architecture" => "senior" })

      payload = diagnostics_payload(double_class.new(canned_text: full_problem_set.to_json))

      expect(payload["requested"]).not_to have_key("kind_difficulty")
      expect(payload["requested"]).not_to have_key("kind_difficulty_chars")
    end

    it "logs level, lock, coverage, the chosen concept, and the block's length" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      allow(WeightedRoll).to receive(:pick).and_call_original
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_return(:application_code)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])
      user.update!(section_kind_levels: { "challenge" => "principal_engineer" }, locked_section_kinds: [ "challenge" ])
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "p")
      set = full_problem_set("challenge" => { "concept" => "n_plus_one" })

      payload = diagnostics_payload(double_class.new(canned_text: set.to_json))
      vocabulary = ProblemSetIngest.selectable_vocabulary_for("challenge", "ruby_rails", mode: :application_code)

      expect(payload["requested"]["kind_difficulty"]).to eq(
        "challenge" => { "level" => "principal_engineer", "locked" => true,
                         "ladder_coverage" => "1/#{vocabulary.size}",
                         "chosen_concept" => "n_plus_one", "chosen_grounded" => true }
      )
      expect(payload["requested"]["kind_difficulty_chars"]).to be > 0
    end
  end

  describe "#build_review_day_context" do
    [ 1, 2, 3 ].each do |count|
      it "grades an exact #{count}-block positional answer as strong" do
        exercise = DailyExercise.new(language: "ruby_rails",
          problem_set: { "parsons_problem" => { "blocks" => Array.new(count) { |i| "block #{i}" } } })
        response = DailyResponse.new(daily_exercise: exercise,
          answers: { "parsons_problem" => "order:#{(0...count).to_a.join(',')}" })
        review = { "rating" => "beginner" }

        service.send(:override_parsons_section_rating!, review, exercise, response)

        expect(review["rating"]).to eq("strong")
        expect(service.send(:section_grading_note, exercise, response, "parsons_problem"))
          .to include("0 block(s) out of place")
      end
    end

    [ "add index", "Approach:\nWhy:" ].each do |answer|
      it "treats #{answer.inspect} as skipped in grading and re-explanation" do
        exercise = DailyExercise.new(language: "ruby_rails", problem_set: {
          "pattern" => { "question" => "Why?", "answer_scaffold" => [ "Approach:", "Why:" ] }
        })
        resp = DailyResponse.new(daily_exercise: exercise,
          answers: { "pattern" => answer }, ai_review: { "pattern" => {} })
        svc = double_class.new(canned_text: "A different explanation")

        context = svc.send(:build_review_day_context, "Rails", exercise, resp)
        expect(context).to include("Their answer: (skipped)")
        expect(context).not_to include(answer)
        expect(svc).to receive(:call).with(hash_including(prompt: include("Their answer: (skipped)"))).and_call_original
        svc.explain_differently(user, exercise, resp, section: "pattern")
        expect(svc).to receive(:call).with(hash_including(prompt: include("Their answer was: (skipped)"))).and_call_original
        svc.answer_follow_up(user, exercise, resp, section: "pattern", question: "Why?", thread: [])
      end
    end

    it "treats short pseudocode as skipped without changing substantive pseudocode" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: { "pseudocode_to_code" => {} })
      resp = DailyResponse.new(daily_exercise: exercise, answers: { "pseudocode_to_code" => "add index" })
      expect(service.send(:build_review_day_context, "Rails", exercise, resp))
        .to include("Their final pseudocode: (skipped)")

      resp.answers["pseudocode_to_code"] = "For each item, collect its unique identifier"
      expect(service.send(:build_review_day_context, "Rails", exercise, resp))
        .to include("Their final pseudocode: For each item, collect its unique identifier")
    end

    def exercise_with_third(third_key, third_section)
      DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "cr?", "snippet" => "code" },
        "pattern"     => { "title" => "P", "question" => "pat?" },
        third_key     => third_section
      })
    end

    it "includes all three sections' questions, answers, and self-ratings" do
      exercise = exercise_with_third("challenge", { "question" => "Implement uniq_by" })
      resp = DailyResponse.new(
        answers: { "code_review" => "It's an N+1", "pattern" => "Extract a service object", "challenge" => "def uniq_by; end" },
        section_ratings: { "code_review" => "right_level", "pattern" => "too_hard", "challenge" => "too_easy" }
      )

      context = service.send(:build_review_day_context, "Rails", exercise, resp)

      expect(context).to include("cr?", "It's an N+1", "right_level")
      expect(context).to include("pat?", "Extract a service object", "too_hard")
      expect(context).to include("Implement uniq_by", "def uniq_by; end", "too_easy")
    end

    it "names the coach in the framing" do
      exercise = exercise_with_third("challenge", { "question" => "q" })
      resp = DailyResponse.new(answers: {}, section_ratings: {})
      context = service.send(:build_review_day_context, "JavaScript/React", exercise, resp)
      expect(context).to include("senior JavaScript/React engineer")
    end

    it "tells the model it will be asked to grade only one section" do
      exercise = exercise_with_third("challenge", { "question" => "q" })
      resp = DailyResponse.new(answers: {}, section_ratings: {})
      context = service.send(:build_review_day_context, "Rails", exercise, resp)
      expect(context).to match(/grade exactly one/i)
    end
  end

  describe "#build_review_day_context with a fourth section" do
    it "includes the plan_review excerpt, question, answer, and self-rating" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "cr?" }, "pattern" => { "title" => "P", "question" => "pat?" },
        "challenge"   => { "question" => "ch?" },
        "plan_review" => { "title" => "Plan", "question" => "What's wrong?", "plan_excerpt" => "Step 1: hardcode a magic number." }
      })
      resp = DailyResponse.new(answers: { "plan_review" => "The magic number is unjustified" },
                               section_ratings: { "plan_review" => "right_level" })

      context = service.send(:build_review_day_context, "Rails", exercise, resp)
      expect(context).to include("What's wrong?", "Step 1: hardcode a magic number.", "The magic number is unjustified", "right_level")
    end

    it "includes the ambiguity_hunt request, planted ambiguities, answer, and self-rating" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "cr?" }, "pattern" => { "title" => "P", "question" => "pat?" },
        "challenge"   => { "question" => "ch?" },
        "ambiguity_hunt" => {
          "title" => "Req", "question" => "What's unclear?", "request" => "Add a leaderboard feature.",
          "planted_ambiguities" => [ "No scope for which users appear", "No tie-breaking rule" ]
        }
      })
      resp = DailyResponse.new(answers: { "ambiguity_hunt" => "Which users are ranked?" },
                               section_ratings: { "ambiguity_hunt" => "too_hard" })

      context = service.send(:build_review_day_context, "Rails", exercise, resp)
      expect(context).to include("Add a leaderboard feature.", "No scope for which users appear", "No tie-breaking rule",
                                 "Which users are ranked?", "too_hard")
    end

    it "contributes nothing for an old exercise with no fourth-slot key" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "cr?" }, "pattern" => { "title" => "P", "question" => "pat?" },
        "challenge"   => { "question" => "ch?" }
      })
      resp = DailyResponse.new(answers: {}, section_ratings: {})

      expect(exercise.fourth_key).to be_nil
      context = service.send(:build_review_day_context, "Rails", exercise, resp)
      expect(context).not_to match(/plan review|ambiguity hunt/i)
    end
  end

  describe "#build_review_day_context" do
    let(:user) { User.create!(email: "review@example.com", name: "Review") }
    let(:service) { FakeService.new("fake-key") }

    def exercise_with(problem_set)
      DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails",
                            generated_at: Time.current, problem_set: problem_set)
    end

    it "does not raise when the day has no pattern section" do
      exercise = exercise_with(
        "code_review" => { "question" => "q", "snippet" => "s" },
        "challenge"   => { "question" => "c" }
      )
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                       answers: { "code_review" => "a" })

      expect { service.send(:build_review_day_context, "Rails", exercise, response) }.not_to raise_error
    end

    it "states the real section count rather than four" do
      exercise = exercise_with(
        "code_review" => { "question" => "q", "snippet" => "s" },
        "challenge"   => { "question" => "c" }
      )
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {})

      context = service.send(:build_review_day_context, "Rails", exercise, response)

      expect(context).to include("the day's 2 sections")
      expect(context).not_to include("four sections")
    end

    it "pluralizes the 'others' clause correctly for a 2-section day" do
      exercise = exercise_with(
        "code_review" => { "question" => "q", "snippet" => "s" },
        "challenge"   => { "question" => "c" }
      )
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {})

      context = service.send(:build_review_day_context, "Rails", exercise, response)

      expect(context).to include("the other section is given here")
      expect(context).not_to include("the 1 others")
    end
  end

  describe "grading notes for the fourth-slot kinds" do
    it "instructs grading against the planted list for ambiguity_hunt" do
      note = ExerciseSection::AmbiguityHunt.grading_note(section: {}, answer: nil)
      expect(note).to match(/planted/i)
      expect(note).to match(/empty string/i)
    end

    it "instructs evaluating pushback quality and a revised plan for plan_review" do
      note = ExerciseSection::PlanReview.grading_note(section: {}, answer: nil)
      expect(note).to match(/revised/i)
    end

    # The registry answers every per-kind question; a kind with nothing extra
    # to say gets the generic rubric rather than a branch at the call site.
    it "is empty for a kind the generic rubric already grades" do
      expect(ExerciseSection::Challenge.grading_note(section: {}, answer: nil)).to eq("")
    end
  end

  describe "#build_review_section_prompt" do
    def exercise_with_third(third_key, third_section)
      DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "cr?", "snippet" => "code" },
        "pattern"     => { "title" => "P", "question" => "pat?" },
        third_key     => third_section
      })
    end

    it "asks for correct/missed/better_questions as arrays and next_step as a string, ungrouped" do
      exercise = exercise_with_third("challenge", { "question" => "q" })
      resp = DailyResponse.new(answers: {})
      prompt = service.send(:build_review_section_prompt, exercise, resp, "code_review")

      expect(prompt).to include('NOT wrapped in a "code_review" key')
      expect(prompt).to include('"correct": array of strings')
      expect(prompt).to include('"missed": array of strings')
      expect(prompt).to include('"better_questions": array of strings')
      expect(prompt).to include('"next_step": string')
      expect(prompt).to match(/separate ideas belong in separate entries/i)
    end

    it "names pattern as structural and asks for a refactored structure" do
      exercise = exercise_with_third("challenge", { "question" => "q" })
      resp = DailyResponse.new(answers: {})
      prompt = service.send(:build_review_section_prompt, exercise, resp, "pattern")
      expect(prompt).to match(/refactored structure/i)
    end

    it "evaluates architecture on depth of reasoning, not correctness, and forbids improved_code" do
      exercise = exercise_with_third("architecture", { "title" => "A", "question" => "q", "scenario" => "s" })
      resp = DailyResponse.new(answers: {})
      prompt = service.send(:build_review_section_prompt, exercise, resp, "architecture")

      expect(prompt.downcase).to include("tradeoff")
      expect(prompt.downcase).to include("alternatives")
      expect(prompt).to include("must be an empty string for this section")
    end

    it "evaluates security_review on vulnerability + mitigation with partial credit" do
      exercise = exercise_with_third("security_review", { "title" => "S", "question" => "q", "snippet" => "code" })
      resp = DailyResponse.new(answers: {})
      prompt = service.send(:build_review_section_prompt, exercise, resp, "security_review")

      expect(prompt.downcase).to include("mitigation")
      expect(prompt.downcase).to include("partial credit")
    end

    it "grounds parsons_problem in the verified mismatch count and forbids improved_code" do
      exercise = exercise_with_third("parsons_problem", {
        "title" => "T", "question" => "Q", "blocks" => %w[a b c d e]
      })
      resp = DailyResponse.new(answers: { "parsons_problem" => "order:0,2,1,3,4" })
      prompt = service.send(:build_review_section_prompt, exercise, resp, "parsons_problem")

      expect(prompt).to match(/2 block\(s\) out of place/)
      expect(prompt).to match(/do not.*judge|not.*re-judge/i)
      expect(prompt).to include('must be an empty string')
    end

    it "does not claim a verified parsons result when the exercise has no blocks array" do
      exercise = exercise_with_third("parsons_problem", { "title" => "T", "question" => "Q" })
      resp = DailyResponse.new(answers: {})
      prompt = service.send(:build_review_section_prompt, exercise, resp, "parsons_problem")
      expect(prompt).not_to match(/block\(s\) out of place/)
      expect(prompt).to include("CANNOT be verified")
    end
  end

  describe "#override_parsons_section_rating!" do
    it "always uses the locally computed rating, discarding whatever the model returned" do
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
        answers: { "parsons_problem" => "order:0,1,2,3,4" }
      )
      review = { "rating" => "beginner" }

      service.send(:override_parsons_section_rating!, review, exercise, response)

      expect(review["rating"]).to eq("strong")
    end

    # The stored answer is a free-form permitted param, so a correct
    # permutation with junk appended must not persist a "strong" rating.
    it "refuses an answer that is a correct permutation plus extra ids" do
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
        answers: { "parsons_problem" => "order:0,1,2,3,4,999" }
      )
      review = { "rating" => "solid" }

      service.send(:override_parsons_section_rating!, review, exercise, response)

      expect(review["rating"]).to eq("beginner")
    end

    it "does nothing when the exercise's parsons_problem has no blocks" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review"     => { "question" => "q", "snippet" => "s" },
          "pattern"         => { "title" => "t", "question" => "q" },
          "parsons_problem" => { "title" => "T", "question" => "Q" }
        }
      )
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {})
      review = { "rating" => "developing" }

      service.send(:override_parsons_section_rating!, review, exercise, response)

      expect(review["rating"]).to eq("developing")
    end
  end

  describe "read timeout per call type" do
    def exercise_and_response_for_review
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
        answers: { "code_review" => "a" * 20 }, submitted_at: Time.current
      )
      [ exercise, response ]
    end

    it "sends the generation call with the long generation budget" do
      svc = double_class.new(canned_text: full_problem_set.to_json)
      svc.generate_exercise(user)

      expect(svc.last_read_timeout).to eq(AiService::GENERATION_READ_TIMEOUT)
    end

    # A blocking generation holds a Puma thread with a user waiting on the
    # response (no caller makes one today; see SYNC_GENERATION_READ_TIMEOUT).
    # It needs more room than a short call and much less than the worker's.
    it "tightens the budget when a request thread is blocked on the call" do
      svc = double_class.new(canned_text: full_problem_set.to_json)
      svc.generate_exercise(user, blocking: true)

      expect(svc.last_read_timeout).to eq(AiService::SYNC_GENERATION_READ_TIMEOUT)
    end

    it "keeps the blocking budget between the short-call and worker budgets" do
      expect(AiService::SYNC_GENERATION_READ_TIMEOUT).to be > AiService::READ_TIMEOUT
      expect(AiService::SYNC_GENERATION_READ_TIMEOUT).to be < AiService::GENERATION_READ_TIMEOUT
    end

    # .call_budget_seconds takes the timeout as an argument rather than closing
    # over READ_TIMEOUT, precisely so a poller waiting on a call made with a
    # different timeout (learn/show.html.erb, CONCEPT_REFERENCE_READ_TIMEOUT)
    # derives its wait from the timeout that call actually uses.
    it "computes the worst-case wait for whichever read timeout it is given" do
      expect(AiService.call_budget_seconds(AiService::READ_TIMEOUT))
        .to eq((AiService::READ_TIMEOUT * (AiService::RETRY_MAX + 1)) + (AiService::RETRY_MAX * AiService::RETRY_MAX_INTERVAL))

      expect(AiService.call_budget_seconds(AiService::CONCEPT_REFERENCE_READ_TIMEOUT))
        .to be > AiService.call_budget_seconds(AiService::READ_TIMEOUT)
    end

    # A review issues three kinds of call — the grading call per section, the one
    # difficulty assessment, and the pre-grading translation on the days that
    # have a kind needing one — and the request thread is blocked on all of
    # them, so the claim-window arithmetic above has to know the budget of
    # every one. Both examples assert the whole map of purposes to budgets, so
    # a new kind of call appearing has to be looked at rather than silently
    # inheriting a budget. This one covers a day with no translation; the next
    # covers one with.
    #
    # Grading gets REVIEW_READ_TIMEOUT because a full-length answer with an
    # improved_code rewrite takes longer than READ_TIMEOUT to grade. The
    # difficulty note stays short: the review waits only
    # DIFFICULTY_ASSESSMENT_GRACE_SECONDS for it once grading is done.
    it "sends each grading call with the review budget and the difficulty note with the short one" do
      exercise, response = exercise_and_response_for_review
      review = { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" }
      svc = double_class.new(canned_text: review.to_json)

      svc.review_sections(user, exercise, response, sections: %w[code_review])

      expect(double_class.read_timeouts_by_purpose).to contain_exactly(
        [ "review_response",   AiService::REVIEW_READ_TIMEOUT ],
        [ "assess_difficulty", AiService::READ_TIMEOUT ]
      )
    end

    # The translation the grade waits on stays on the short budget, which is
    # the first leg of the claim-window arithmetic above.
    it "leaves the pre-grading translation on the short budget" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "question" => "cr?", "snippet" => "code" },
                       "pseudocode_to_code" => { "title" => "P2C", "problem_statement" => "merge ranges" } }
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "pseudocode_to_code" => "a" * 20 }, submitted_at: Time.current
      )
      svc = double_class.new(canned_text: { "rating" => "solid" }.to_json)

      svc.review_sections(user, exercise, response, sections: %w[pseudocode_to_code])

      expect(double_class.read_timeouts_by_purpose).to contain_exactly(
        [ "pseudocode_translate", AiService::READ_TIMEOUT ],
        [ "review_response",      AiService::REVIEW_READ_TIMEOUT ],
        [ "assess_difficulty",    AiService::READ_TIMEOUT ]
      )
    end
  end

  describe "#review_sections" do
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

    it "returns an ok: true result per requested section on success" do
      exercise, response = exercise_and_response
      review = { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" }
      svc = double_class.new(canned_text: review.to_json)

      results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern])

      expect(results.keys).to match_array(%w[code_review pattern])
      expect(results["code_review"]).to eq(ok: true, review: review)
      expect(results["pattern"]).to eq(ok: true, review: review)
    end

    it "logs one ApiUsage row per requested section" do
      exercise, response = exercise_and_response
      svc = double_class.new(canned_text: { "rating" => "solid" }.to_json, input_tokens: 10, output_tokens: 20)

      expect {
        svc.review_sections(user, exercise, response, sections: %w[code_review pattern challenge])
      }.to change { ApiUsage.where(purpose: "review_response").count }.by(3)
    end

    # A grading thread that hits pool exhaustion used to propagate through
    # Thread#value past ResponsesController#review's rescues: a 500 on a request
    # whose other sections had already graded, their results discarded after
    # being billed, and the review claim held until it went stale.
    it "tags an infrastructure failure rather than losing the sections that graded" do
      exercise, response = exercise_and_response
      starved_class = Class.new(AiService) do
        def initialize(_api_key = nil, canned_text: "{}")
          @canned_text = canned_text
        end

        private

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          raise ActiveRecord::ConnectionTimeoutError, "could not obtain a connection" if prompt.include?('"pattern"')

          { text: @canned_text, input_tokens: 1, output_tokens: 1, truncated: false }
        end

        def build_connection = nil
      end
      svc = starved_class.new(canned_text: { "rating" => "solid" }.to_json)

      results = nil
      expect { results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern]) }
        .not_to raise_error

      expect(results["code_review"][:ok]).to be(true)
      expect(results["pattern"]).to include(ok: false, error_code: "other")
    end

    # The other half of the split, and the reason it is a split at all: swallow
    # everything here and a real bug reaches the engineer as "couldn't be
    # reviewed, try again", which is a retry button over a stack trace nobody
    # ever sees.
    it "lets a programming error through rather than dressing it up as a retryable failure" do
      exercise, response = exercise_and_response
      buggy_class = Class.new(AiService) do
        def initialize(_api_key = nil) = nil

        private

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          nil.this_method_does_not_exist
        end

        def build_connection = nil
      end

      # Thread#report_on_exception would print the (expected) backtrace to
      # stderr on every run, which is noise in a suite where a clean log is how
      # a real thread failure gets noticed.
      was_reporting = Thread.report_on_exception
      Thread.report_on_exception = false

      expect { buggy_class.new.review_sections(user, exercise, response, sections: %w[code_review]) }
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

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          @calls += 1
          raise AiService::RateLimitError, "rate limited" if prompt.include?('"pattern"')
          { text: @canned_text, input_tokens: 1, output_tokens: 1, truncated: false }
        end

        def build_connection = nil
      end
      svc = failing_class.new(canned_text: { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" }.to_json)

      results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern])

      expect(results["code_review"][:ok]).to be(true)
      expect(results["pattern"]).to eq(ok: false, error_code: "rate_limit", message: "rate limited")
    end

    # Regression for a pool-exhaustion bug: each review thread used to hold a
    # checked-out connection for the entire (up to READ_TIMEOUT-second)
    # provider call, even though the only DB work is ApiUsage.create! in
    # #log_usage. With Puma's thread count matching database.yml's pool size,
    # that left zero spare connections for any concurrent request. #call_and_log
    # now scopes the checkout to #log_usage alone, so the thread must hold no
    # connection while #call — the provider HTTP round trip — is running.
    it "holds no pooled connection for the review thread while the provider call is in flight" do
      exercise, response = exercise_and_response

      probing_class = Class.new(AiService) do
        class << self
          attr_accessor :held_connection_during_call
        end

        def initialize(_api_key = nil)
          @canned_text = { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [],
                           "next_step" => "", "improved_code" => "" }.to_json
        end

        private

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          # #active_connection? returns the leased connection object or nil (not a
          # boolean) — see ActiveRecord::ConnectionAdapters::ConnectionPool#active_connection?.
          self.class.held_connection_during_call = ActiveRecord::Base.connection_pool.active_connection?
          { text: @canned_text, input_tokens: 1, output_tokens: 1, truncated: false }
        end

        def build_connection = nil
      end

      probing_class.new.review_sections(user, exercise, response, sections: %w[code_review])

      expect(probing_class.held_connection_during_call).to be_nil
    end

    it "maps AuthenticationError to its error code" do
      exercise, response = exercise_and_response

      auth_failing = Class.new(AiService) do
        private
        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil) = raise(AiService::AuthenticationError, "bad key")
        def build_connection = nil
      end.new("fake_key")

      results = auth_failing.review_sections(user, exercise, response, sections: %w[code_review])
      expect(results["code_review"][:error_code]).to eq("authentication")
    end

    it "applies override_parsons_section_rating! only when parsons_problem is requested and succeeds" do
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
      svc = double_class.new(canned_text: { "rating" => "beginner" }.to_json)

      results = svc.review_sections(user, exercise, response, sections: %w[parsons_problem])

      expect(results["parsons_problem"][:review]["rating"]).to eq("strong")
    end
  end

  describe "#explain_concept_differently" do
    let(:reference) do
      ConceptReference.new(concept: "n_plus_one", language: "ruby_rails",
                           tagline: "One query per row is the smell",
                           explanation: "The association loads once per iteration.",
                           code_example: "Post.all.each { |p| p.author.name }",
                           senior_lens: "Reach for includes before the loop exists.")
    end

    let(:capturing_class) do
      Class.new(double_class) do
        attr_reader :last_system, :last_prompt, :last_max_tokens
        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          @last_system = system
          @last_prompt = prompt
          @last_max_tokens = max_tokens
          super
        end
      end
    end

    it "sends the concept, every field of the reference already read, and prior framings" do
      svc = capturing_class.new(canned_text: "Picture a library courier.")

      result = svc.explain_concept_differently(user, reference,
                                               prior_alternates: [ "A restaurant-orders analogy" ])

      expect(result).to eq("Picture a library courier.")
      expect(svc.last_prompt).to include("n_plus_one")
      AiService::CONCEPT_REFERENCE_FIELDS.each do |field|
        expect(svc.last_prompt).to include(reference.public_send(field))
      end
      expect(svc.last_prompt).to include("A restaurant-orders analogy")
      expect(svc.last_prompt).to include("do NOT reprise these angles")
    end

    # The point of the whole surface: this runs before a day is submitted, so it
    # must teach the concept without being able to reach the day's problem. The
    # signature is what makes that true — there is no argument to pass one in.
    it "cannot see today's problem, because it has no exercise or response argument" do
      params = AiService.instance_method(:explain_concept_differently).parameters

      expect(params).not_to include([ :req, :exercise ], [ :req, :daily_response ])
      expect(params.map(&:last)).to contain_exactly(:user, :reference, :prior_alternates)
    end

    it "states the durable-reference scope the generating prompt states" do
      svc = capturing_class.new(canned_text: "Another angle.")

      svc.explain_concept_differently(user, reference)

      expect(svc.last_prompt).to include(AiService::CONCEPT_REFERENCE_SCOPE)
      expect(svc.last_prompt).to match(/never solve, hint at,\s+or refer to any particular exercise/)
    end

    # reference.language is the ConceptBucket, so a bucket with no programming
    # language of its own has to resolve too.
    it "resolves a language-independent bucket" do
      svc = capturing_class.new(canned_text: "Another angle.")
      arch = ConceptReference.new(concept: "scaling_bottlenecks", language: "architecture",
                                  tagline: "t", explanation: "e", code_example: "c", senior_lens: "s")

      expect { svc.explain_concept_differently(user, arch) }.not_to raise_error
      expect(svc.last_system).to include("re-teaching one concept")
    end

    it "caps its own reply, which is also what turns off extended thinking" do
      svc = capturing_class.new(canned_text: "Another angle.")

      svc.explain_concept_differently(user, reference)

      expect(svc.last_max_tokens).to eq(AiService::CONCEPT_ALTERNATE_MAX_TOKENS)
    end

    it "logs usage under its own purpose" do
      svc = double_class.new(canned_text: "Another angle.")

      expect {
        svc.explain_concept_differently(user, reference)
      }.to change { ApiUsage.where(purpose: "explain_concept_differently").count }.by(1)
    end

    it "raises InvalidResponseError instead of returning a blank alternate" do
      svc = double_class.new(canned_text: "   ")

      expect {
        svc.explain_concept_differently(user, reference)
      }.to raise_error(AiService::InvalidResponseError)
    end
  end

  # The design constraint made mechanical, the same way the essential-vs-
  # abstraction standard is: one source, two consumers. Two independently
  # worded copies fail here, and so does a future edit that inlines either one.
  # The two prompts name their subject differently — one re-teaches a concept,
  # the other reframes a point — so the shared source takes that noun and the
  # rule after it is what cannot drift.
  describe "the shared explain-differently standard" do
    # Asserting that the rule's TEXT appears would pass just as happily if a
    # consumer went back to its own inline copy — which is the duplication this
    # exists to prevent, and the likeliest way it comes back. A sentinel can
    # only reach a prompt through the shared method, so inlining either
    # consumer fails here even when the inlined wording is identical.
    let(:sentinel_class) do
      Class.new(double_class) do
        attr_reader :last_prompt

        def self.explain_differently_standard(subject)
          "<<explain-differently:#{subject}>>"
        end

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          @last_prompt = prompt
          super
        end
      end
    end

    it "reaches both consumers from one source" do
      reference = ConceptReference.new(concept: "n_plus_one", language: "ruby_rails",
                                       tagline: "t", explanation: "e",
                                       code_example: "c", senior_lens: "s")
      concept_svc = sentinel_class.new(canned_text: "Another angle.")
      concept_svc.explain_concept_differently(user, reference, prior_alternates: [])

      exercise = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "Find the N+1", "snippet" => "code" }
      })
      resp = DailyResponse.new(answers: { "code_review" => "Looks fine" },
                               ai_review: { "code_review" => { "missed" => [ "loaded per row" ] } })
      point_svc = sentinel_class.new(canned_text: "Another angle.")
      point_svc.explain_differently(user, exercise, resp, section: "code_review", prior_alternates: [])

      expect(concept_svc.last_prompt).to include("<<explain-differently:concept>>")
      expect(point_svc.last_prompt).to include("<<explain-differently:point>>")
    end

    # The two differ by the subject noun and nothing else. Without this, the
    # method could grow a second divergence and both assertions above would
    # still pass.
    it "differs between the two only by the subject it names" do
      concept = AiService.explain_differently_standard("concept")
      point   = AiService.explain_differently_standard("point")

      expect(concept.sub("SAME concept", "SAME point")).to eq(point)
    end
  end

  describe "#explain_differently" do
    it "sends the section's question, answer, missed points, and prior alternates" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "Find the N+1", "snippet" => "code" }
      })
      resp = DailyResponse.new(
        answers: { "code_review" => "Looks fine to me" },
        ai_review: { "code_review" => { "missed" => [ "The association is loaded per row" ] } }
      )

      spy_class = Class.new(double_class) do
        attr_reader :last_prompt
        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          @last_prompt = prompt
          super
        end
      end
      svc = spy_class.new(canned_text: "Think of it like fetching one book at a time.")

      result = svc.explain_differently(user, exercise, resp, section: "code_review",
                                       prior_alternates: [ "A restaurant-orders analogy" ])

      expect(result).to eq("Think of it like fetching one book at a time.")
      expect(svc.last_prompt).to include("Find the N+1")
      expect(svc.last_prompt).to include("Looks fine to me")
      expect(svc.last_prompt).to include("The association is loaded per row")
      expect(svc.last_prompt).to include("A restaurant-orders analogy")
    end

    it "logs usage under its own purpose" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: { "code_review" => { "question" => "q" } })
      resp = DailyResponse.new(answers: {}, ai_review: { "code_review" => {} })
      svc = double_class.new(canned_text: "An alternate framing")

      expect {
        svc.explain_differently(user, exercise, resp, section: "code_review", prior_alternates: [])
      }.to change { ApiUsage.where(purpose: "explain_differently").count }.by(1)
    end

    it "raises InvalidResponseError instead of returning a blank alternate" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: { "code_review" => { "question" => "q" } })
      resp = DailyResponse.new(answers: {}, ai_review: { "code_review" => {} })
      svc = double_class.new(canned_text: "   ")

      expect {
        svc.explain_differently(user, exercise, resp, section: "code_review", prior_alternates: [])
      }.to raise_error(AiService::InvalidResponseError)
    end
  end

  describe "#answer_follow_up" do
    it "sends the question, the section's review, and the prior thread in order" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "Find the N+1", "snippet" => "code" }
      })
      resp = DailyResponse.new(
        answers: { "code_review" => "Looks fine" },
        ai_review: { "code_review" => { "missed" => [ "loads per row" ] } }
      )
      thread = [
        { role: "user",      content: "Why is that slow?" },
        { role: "assistant", content: "Each row triggers its own query." }
      ]

      spy_class = Class.new(double_class) do
        attr_reader :last_prompt, :last_system, :last_history
        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          @last_system  = system
          @last_prompt  = prompt
          @last_history = history
          super
        end
      end
      svc = spy_class.new(canned_text: "Because the database round-trip dominates.")

      result = svc.answer_follow_up(user, exercise, resp, section: "code_review",
                                    question: "Does eager loading always help?", thread: thread)

      expect(result).to eq("Because the database round-trip dominates.")
      expect(svc.last_prompt).to include("Does eager loading always help?")
      expect(svc.last_system).to include("loads per row")
      expect(svc.last_history).to eq(thread)
      expect(svc.last_prompt).not_to include("Why is that slow?")
      expect(svc.last_prompt).not_to include("Each row triggers its own query.")
    end

    it "logs usage under its own purpose" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: { "code_review" => { "question" => "q" } })
      resp = DailyResponse.new(answers: {}, ai_review: { "code_review" => {} })
      svc = double_class.new(canned_text: "An answer")

      expect {
        svc.answer_follow_up(user, exercise, resp, section: "code_review", question: "Why?", thread: [])
      }.to change { ApiUsage.where(purpose: "review_follow_up").count }.by(1)
    end

    it "raises InvalidResponseError instead of returning a blank answer" do
      exercise = DailyExercise.new(language: "ruby_rails", problem_set: { "code_review" => { "question" => "q" } })
      resp = DailyResponse.new(answers: {}, ai_review: { "code_review" => {} })
      svc = double_class.new(canned_text: "")

      expect {
        svc.answer_follow_up(user, exercise, resp, section: "code_review", question: "Why?", thread: [])
      }.to raise_error(AiService::InvalidResponseError)
    end
  end

  describe "the pseudocode_to_code rounds" do
    let(:user) { User.create!(email: "pseudo-#{SecureRandom.hex(4)}@example.com", name: "P") }

    let(:exercise) do
      DailyExercise.new(language: "ruby_rails", problem_set: {
        "pseudocode_to_code" => {
          "title" => "Merge ranges",
          "problem_statement" => "Merge overlapping ranges. The list may be empty.",
          "question" => "Write pseudocode for this."
        }
      })
    end

    # Captures `system:` as well as `prompt:`, which the shared double_class
    # does not expose — both round prompts are asserted against below.
    let(:spy_class) do
      Class.new(double_class) do
        attr_reader :last_prompt, :last_system

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          @last_system = system
          @last_prompt = prompt
          super
        end
      end
    end

    def critique_with(text)
      spy_class.new(canned_text: text)
        .critique_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "sort then walk")
    end

    describe "#critique_pseudocode" do
      it "returns the typed flag and the bounded points" do
        result = critique_with({ gaps_found: true, gaps: [ "No empty-input case." ] }.to_json)

        expect(result[:gaps_found]).to be(true)
        expect(result[:gaps]).to eq([ "No empty-input case." ])
      end

      it "distinguishes 'found nothing' from 'came back malformed'" do
        result = critique_with({ gaps_found: false, gaps: [] }.to_json)

        expect(result[:gaps_found]).to be(false)
        expect(result[:gaps]).to be_empty
      end

      # The whole reason gaps_found is a typed field: an empty list is ALSO what
      # a garbage response normalizes to, so the list can never be the signal.
      it "raises when it claims gaps and delivers none usable" do
        expect { critique_with({ gaps_found: true, gaps: [ "", "   ", 7 ] }.to_json) }
          .to raise_error(AiService::InvalidResponseError, /claimed gaps/i)
      end

      it "raises when gaps_found is missing or not a boolean" do
        expect { critique_with({ gaps: [ "something" ] }.to_json) }
          .to raise_error(AiService::InvalidResponseError, /gaps_found/)
        expect { critique_with({ gaps_found: "yes", gaps: [ "something" ] }.to_json) }
          .to raise_error(AiService::InvalidResponseError, /gaps_found/)
      end

      it "caps the points at the kind's bound" do
        result = critique_with({ gaps_found: true, gaps: %w[a b c d].map { |c| c * 40 } }.to_json)

        expect(result[:gaps].size).to eq(ExerciseSection::PseudocodeToCode::MAX_CRITIQUE_POINTS)
      end

      it "drops the list entirely when the flag says nothing was found" do
        result = critique_with({ gaps_found: false, gaps: [ "leaked point" ] }.to_json)

        expect(result[:gaps]).to eq([])
      end

      it "logs its own usage purpose" do
        svc = spy_class.new(canned_text: { gaps_found: false, gaps: [] }.to_json)

        expect { svc.critique_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "x") }
          .to change { ApiUsage.where(purpose: "pseudocode_critique").count }.by(1)
      end

      it "logs counts only, never the plan or the critique text" do
        logged = []
        allow(Rails.logger).to receive(:info) { |msg| logged << msg.to_s if msg.to_s.start_with?("[pseudocode]") }

        spy_class.new(canned_text: { gaps_found: false, gaps: [] }.to_json)
          .critique_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "my secret plan text")

        expect(logged.size).to eq(1)
        expect(logged.first).to include("phase=critique", "gaps_found=false", "gaps=0", "user=#{user.id}")
        expect(logged.first).not_to include("my secret plan text")
      end
    end

    describe "#translate_pseudocode" do
      def translate_with(text, pseudocode: "sort then walk")
        spy_class.new(canned_text: text)
          .translate_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: pseudocode)
      end

      it "returns the generated code and logs its own purpose" do
        svc = spy_class.new(canned_text: "def merge(r)\nend")

        expect {
          code = svc.translate_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "sort then walk")
          expect(code).to include("def merge")
        }.to change { ApiUsage.where(purpose: "pseudocode_translate").count }.by(1)
      end

      it "rejects a blank translation rather than storing it" do
        expect { translate_with("   ") }.to raise_error(AiService::InvalidResponseError)
      end

      # Rejected, not truncated: cutting source mid-token yields code that is no
      # longer what the plan said, which the page then captions as "your plan
      # implemented literally" and the review grades them on. Raising also keeps
      # the round unspent, so the engineer can retry.
      it "rejects a runaway translation rather than cutting it into something else" do
        expect { translate_with("x" * 20_000) }
          .to raise_error(AiService::InvalidResponseError, /too long/i)
      end

      it "accepts a translation right at the limit" do
        code = translate_with("x" * AiService::MAX_GENERATED_CODE_LENGTH)

        expect(code.length).to eq(AiService::MAX_GENERATED_CODE_LENGTH)
      end

      it "sends the pseudocode and the day's language, never a request to improve it" do
        svc = spy_class.new(canned_text: "def f; end")
        svc.translate_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "sort then walk")

        expect(svc.last_prompt).to include("sort then walk", "Ruby/Rails")
        expect(svc.last_prompt).to include("never for filling gaps")
      end

      # Faithfulness cannot be asserted against a live model, so what IS asserted
      # is that every prohibition reaches the prompt. The behavioural half is
      # FakeService::PSEUDOCODE_TRANSLATION plus the system spec.
      it "forbids every form of silent correction in its system prompt" do
        system_prompt = AiService::PSEUDOCODE_TRANSLATE_SYSTEM_PROMPT

        expect(system_prompt).to match(/omits an edge case, the code omits it too/i)
        expect(system_prompt).to match(/implement the wrong thing/i)
        expect(system_prompt).to match(/do not add error handling/i)
        expect(system_prompt).to match(/do not add comments/i)
        expect(system_prompt).to match(/syntactically valid/i)
      end
    end

    # CLAUDE.md forbids a constant justified by a vocabulary's or schema's size
    # unless it derives from that size or a spec asserts the assumption. This is
    # the spec: a flat 300 sat below the largest VALID critique, so a maximal
    # three-point response truncated mid-JSON and surfaced as a parse failure.
    it "budgets enough tokens for the largest critique its own schema permits" do
      kind  = ExerciseSection::PseudocodeToCode
      chars = kind::MAX_CRITIQUE_POINTS * kind::MAX_CRITIQUE_POINT_LENGTH

      expect(AiService::PSEUDOCODE_CRITIQUE_MAX_TOKENS).to be > chars / 3
      # Still a cheap round-1 call, not a generation-sized one.
      expect(AiService::PSEUDOCODE_CRITIQUE_MAX_TOKENS).to be < ClaudeService::MAX_TOKENS
    end

    it "gives the thinking partner the problem statement, which is the whole task" do
      svc = spy_class.new(canned_text: "A guiding question.")
      svc.duck_response(user, exercise, section: "pseudocode_to_code", message: "stuck", thread: [])

      expect(svc.last_system).to include("Merge overlapping ranges. The list may be empty.")
    end

    # The design constraint made mechanical: one source, two consumers. Two
    # independently-worded copies fail here, and so does a future edit that
    # inlines either one.
    describe "the shared essential-vs-abstraction standard" do
      it "reaches both consumers from one source" do
        standard = ExerciseSection::PseudocodeToCode.gap_standard
        svc      = spy_class.new(canned_text: { gaps_found: false, gaps: [] }.to_json)
        svc.critique_pseudocode(user, exercise, section: "pseudocode_to_code", pseudocode: "x")

        expect(svc.last_system).to include(standard)
        expect(svc.last_prompt).to include(standard)
        expect(ExerciseSection::PseudocodeToCode.grading_note(section: {}, answer: "x")).to include(standard)
      end
    end
  end

  describe "#duck_response" do
    let(:exercise) do
      DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "Find the N+1", "snippet" => "code", "scenario" => "a billing job" }
      })
    end

    # A duck reply is prose, so one that stops early is still worth reading;
    # the JSON entry points keep raising because a cut-off body is unusable.
    it "returns a reply the cap cut short with an ellipsis, and still records usage" do
      svc = double_class.new(canned_text: "Stubbing replaces the method so the test", truncated: true)

      answer = nil
      expect {
        answer = svc.duck_response(user, exercise, section: "code_review", message: "what is stubbing?")
      }.to change { ApiUsage.where(purpose: "duck_thread").count }.by(1)

      expect(answer).to eq("Stubbing replaces the method so the test…")
    end

    it "leaves a complete reply without an ellipsis" do
      svc = double_class.new(canned_text: "What does the stub return?", truncated: false)

      expect(svc.duck_response(user, exercise, section: "code_review", message: "hm")).to eq("What does the stub return?")
    end

    # Local spy: the shared `double_class`'s `#call` doesn't expose `system:`
    # or `history:`, and #duck_response has no `daily_response` argument to
    # read a draft answer from in the first place — this class exists purely
    # to capture the system/history/prompt values this describe block's
    # examples need to inspect.
    let(:duck_spy_class) do
      Class.new(double_class) do
        attr_reader :last_prompt, :last_system, :last_history

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          @last_system  = system
          @last_prompt  = prompt
          @last_history = history
          super
        end
      end
    end

    it "sends the section's question/scenario/snippet in system, the prior thread as history, and the new message in prompt" do
      thread = [
        { role: "user",      content: "What's slow here?" },
        { role: "assistant", content: "What happens inside that loop on each iteration?" }
      ]
      svc = duck_spy_class.new(canned_text: "What would change if the list had a thousand rows instead of ten?")

      result = svc.duck_response(user, exercise, section: "code_review",
                                 message: "I don't see anything wrong", thread: thread)

      expect(result).to eq("What would change if the list had a thousand rows instead of ten?")
      expect(svc.last_system).to include("Find the N+1")
      expect(svc.last_system).to include("a billing job")
      expect(svc.last_history).to eq(thread)
      expect(svc.last_prompt).to include("I don't see anything wrong")
      expect(svc.last_prompt).not_to include("What's slow here?")
    end

    # It is on the engineer's screen, so the duck may talk about it.
    it "sends a grounded migration's current schema along with the snippet" do
      exercise.problem_set["code_review"]["current_schema"] = %(create_table "things" do |t|\nend)
      svc = duck_spy_class.new(canned_text: "A guiding question.")

      svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])

      expect(svc.last_system).to include(%(create_table "things" do |t|))
    end

    it "never sends a draft answer — the method has no daily_response argument to read one from" do
      expect(AiService.instance_method(:duck_response).parameters).not_to include([ :req, :daily_response ])

      svc = duck_spy_class.new(canned_text: "A guiding question.")
      svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])

      expect(svc.last_prompt).not_to include("daily_response")
    end

    it "the system prompt never permits stating the answer or writing corrected code" do
      svc = duck_spy_class.new(canned_text: "A guiding question.")

      svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])

      expect(svc.last_system).to match(/never state the correct answer/i)
      expect(svc.last_system).to match(/complete code/i)
      expect(svc.last_system).to match(/1-3 sentences/i)
    end

    it "allows explaining what the problem is, directly and in plain words" do
      svc = duck_spy_class.new(canned_text: "Think of it like a shopping list you rewrite on every trip.")

      svc.duck_response(user, exercise, section: "code_review",
                        message: AiService::DUCK_EXPLAIN_REQUEST, thread: [])

      expect(svc.last_system).to match(/understanding the problem/i)
      expect(svc.last_system).to match(/answer these directly/i)
      expect(svc.last_system).to match(/analogy/i)
      expect(svc.last_system).to include(AiService::PLAIN_LANGUAGE_STANDARD)
    end

    # The boundary is a judgement the model makes per message, so the prompt
    # has to give it instances to classify against, a rule for the mixed case,
    # and a tie-break — not just a definition.
    it "still forbids solving, and says what to do when the two are mixed or unclear" do
      svc = duck_spy_class.new(canned_text: "A guiding question.")

      svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])

      expect(svc.last_system).to match(/solving the problem/i)
      expect(svc.last_system).to match(/what's the bug\?/i)
      expect(svc.last_system).to match(/mixes both/i)
      expect(svc.last_system).to match(/cannot tell which kind it is, treat it as kind 2/i)
    end

    it "keeps the FakeService dispatch phrase, which every duck system spec routes on" do
      expect(AiService::DUCK_SYSTEM_PROMPT).to include("Socratic thinking partner")
    end

    it "asks for a plain-language explanation rather than the answer" do
      expect(AiService::DUCK_EXPLAIN_REQUEST).to match(/plain language/i)
      expect(AiService::DUCK_EXPLAIN_REQUEST).not_to match(/answer|fix|solve/i)
    end

    # An explanation plus a concrete analogy did not fit in 150 tokens, and an
    # explanation plus a guiding question, the prompt's answer to a mixed
    # message, did not fit in 250. The ceiling stays a budget, not an
    # enforcement mechanism — the prompt is what actually withholds the answer.
    it "gives a reply room for an explanation while staying far below a review's ceiling" do
      expect(AiService::DUCK_RESPONSE_MAX_TOKENS).to eq(400)
      expect(AiService::DUCK_RESPONSE_MAX_TOKENS).to be < ClaudeService::MAX_TOKENS
    end

    it "passes DUCK_RESPONSE_MAX_TOKENS, distinct from other AiService calls' ceilings" do
      svc = double_class.new(canned_text: "A guiding question.")

      svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])

      expect(svc.last_max_tokens).to eq(AiService::DUCK_RESPONSE_MAX_TOKENS)
      expect(AiService::DUCK_RESPONSE_MAX_TOKENS).to be < ClaudeService::MAX_TOKENS
    end

    it "logs usage under its own purpose" do
      svc = double_class.new(canned_text: "A guiding question.")

      expect {
        svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])
      }.to change { ApiUsage.where(purpose: "duck_thread").count }.by(1)
    end

    it "raises InvalidResponseError instead of returning a blank response" do
      svc = double_class.new(canned_text: "   ")

      expect {
        svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])
      }.to raise_error(AiService::InvalidResponseError)
    end

    context "for a parsons_problem section" do
      let(:parsons_exercise) do
        DailyExercise.new(language: "ruby_rails", problem_set: {
          "parsons_problem" => {
            "question"      => "Arrange these blocks",
            "blocks"        => [ "def a", "  work", "end" ],
            "display_order" => [ 2, 0, 1 ]
          }
        })
      end

      it "sends the blocks, without which the model cannot see the code at all" do
        svc = duck_spy_class.new(canned_text: "Which block has to run first?")

        svc.duck_response(user, parsons_exercise, section: "parsons_problem", message: "stuck", thread: [])

        expect(svc.last_system).to include("def a")
        expect(svc.last_system).to include("work")
      end

      it "sends them in the learner's on-screen order, never the stored correct order" do
        svc = duck_spy_class.new(canned_text: "Which block has to run first?")

        svc.duck_response(user, parsons_exercise, section: "parsons_problem", message: "stuck", thread: [])

        expect(svc.last_system).to include("1. end")
        expect(svc.last_system).to include("2. def a")
        expect(svc.last_system).to include("3.   work")
        expect(svc.last_system).to match(/NOT the correct order/)
        expect(svc.last_system.index("1. end")).to be < svc.last_system.index("2. def a")
      end

      it "never emits the stored (solved) order when display_order is missing" do
        exercise_without_order = DailyExercise.new(language: "ruby_rails", problem_set: {
          "parsons_problem" => { "question" => "Arrange", "blocks" => [ "def a", "  work", "end" ] }
        })
        svc = duck_spy_class.new(canned_text: "Which block has to run first?")

        svc.duck_response(user, exercise_without_order, section: "parsons_problem", message: "stuck", thread: [])

        # The blocks are still sent — the model needs the code — but with no
        # positions, since the only order available here is the answer.
        expect(svc.last_system).to include("def a")
        expect(svc.last_system).to include("order withheld")
        expect(svc.last_system).not_to include("1. def a")
        expect(svc.last_system).not_to match(/NOT the correct order/)
      end

      it "refuses an identity display_order, which is the solved order wearing a scramble's name" do
        solved = DailyExercise.new(language: "ruby_rails", problem_set: {
          "parsons_problem" => {
            "question" => "Arrange", "blocks" => [ "def a", "  work", "end" ],
            "display_order" => [ 0, 1, 2 ]
          }
        })
        svc = duck_spy_class.new(canned_text: "Which block has to run first?")

        svc.duck_response(user, solved, section: "parsons_problem", message: "stuck", thread: [])

        expect(svc.last_system).to include("order withheld")
        expect(svc.last_system).not_to include("1. def a")
      end

      it "withholds positions rather than raising on a corrupt display_order" do
        corrupt = DailyExercise.new(language: "ruby_rails", problem_set: {
          "parsons_problem" => {
            "question" => "Arrange", "blocks" => [ "def a", "end" ],
            "display_order" => [ 5, 5 ]
          }
        })
        svc = duck_spy_class.new(canned_text: "Which block has to run first?")

        expect {
          svc.duck_response(user, corrupt, section: "parsons_problem", message: "stuck", thread: [])
        }.not_to raise_error

        expect(svc.last_system).to include("order withheld")
      end

      it "omits the blocks line entirely for a section that has no blocks" do
        svc = duck_spy_class.new(canned_text: "A guiding question.")

        svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])

        expect(svc.last_system).not_to include("NOT the correct order")
      end
    end

    context "for a plan_review section" do
      let(:plan_review_exercise) do
        DailyExercise.new(language: "ruby_rails", problem_set: {
          "plan_review" => {
            "title" => "Cache plan", "question" => "What's wrong?",
            "plan_excerpt" => "Cache the response for 300 seconds and add an admin cache-clear endpoint."
          }
        })
      end

      it "includes the plan excerpt, without which the duck cannot see what's under review" do
        svc = duck_spy_class.new(canned_text: "What happens to a stale cache entry after 300 seconds?")

        svc.duck_response(user, plan_review_exercise, section: "plan_review", message: "stuck", thread: [])

        expect(svc.last_system).to include("Cache the response for 300 seconds")
      end
    end

    context "for an ambiguity_hunt section" do
      let(:ambiguity_hunt_exercise) do
        DailyExercise.new(language: "ruby_rails", problem_set: {
          "ambiguity_hunt" => {
            "title" => "Leaderboard ask", "question" => "What's unclear?",
            "request" => "Add a leaderboard to the dashboard.",
            "planted_ambiguities" => [ "Which metric ranks users is unstated", "Tie-breaking is unstated" ]
          }
        })
      end

      it "includes the feature request, without which the duck cannot see what's being asked" do
        svc = duck_spy_class.new(canned_text: "What would 'top' mean here — most sessions, most points?")

        svc.duck_response(user, ambiguity_hunt_exercise, section: "ambiguity_hunt", message: "stuck", thread: [])

        expect(svc.last_system).to include("Add a leaderboard to the dashboard.")
      end

      it "never leaks planted_ambiguities — that is the hidden grading answer key" do
        svc = duck_spy_class.new(canned_text: "What would 'top' mean here — most sessions, most points?")

        svc.duck_response(user, ambiguity_hunt_exercise, section: "ambiguity_hunt", message: "stuck", thread: [])

        expect(svc.last_system).not_to include("Which metric ranks users is unstated")
        expect(svc.last_system).not_to include("Tie-breaking is unstated")
        expect(svc.last_system).not_to include("planted_ambiguities")
      end
    end
  end

  describe "#duck_response sending real conversational turns" do
    let(:user) { User.create!(email: "duck@example.com", name: "Duck", skill_level: "developing", focus_areas: [], api_key: "fake", provider: "fake") }
    let(:exercise) do
      user.daily_exercises.create!(date: Date.current, language: "ruby_rails",
                                   problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_stringify_keys,
                                   generated_at: Time.current)
    end
    let(:service) { FakeService.new("fake") }

    def captured_call(thread:)
      captured = nil
      allow(service).to receive(:call).and_wrap_original do |original, **kwargs|
        captured = kwargs
        original.call(**kwargs)
      end
      service.duck_response(user, exercise, section: "code_review", message: "why is this slow?", thread: thread)
      captured
    end

    it "sends prior turns as history rather than as prompt text" do
      thread = [
        { role: "user",      content: "is this N+1?" },
        { role: "assistant", content: "what does the loop do?" }
      ]

      kwargs = captured_call(thread: thread)

      expect(kwargs[:history]).to eq(thread)
      expect(kwargs[:prompt]).not_to include("Conversation so far:")
      expect(kwargs[:prompt]).not_to include("is this N+1?")
    end

    # Why it is worth the write premium, and what the bet is, live in CLAUDE.md
    # under "Conversational calls send real turns" — the numbers are the
    # provider's and they move.
    it "asks for the system prompt to be cached" do
      expect(captured_call(thread: [])[:cache_system]).to be(true)
    end

    it "moves the section context into system, where it is sent once" do
      kwargs = captured_call(thread: [])

      expect(kwargs[:system]).to include(AiService::DUCK_SYSTEM_PROMPT)
      expect(kwargs[:system]).to include(exercise.problem_set.dig("code_review", "question"))
      expect(kwargs[:prompt]).not_to include(exercise.problem_set.dig("code_review", "question"))
    end

    it "keeps the per-turn directive attached to the new turn" do
      kwargs = captured_call(thread: [])

      expect(kwargs[:prompt]).to include("why is this slow?")
      expect(kwargs[:prompt]).to include("Respond as their Socratic thinking partner")
    end

    # Caching moved from "no" to "yes" here deliberately (issue #151); the
    # assertion lives in its own example above rather than riding along with
    # the output ceiling, which is a separate guarantee.
    it "keeps its output ceiling" do
      expect(captured_call(thread: [])[:max_tokens]).to eq(AiService::DUCK_RESPONSE_MAX_TOKENS)
    end

    # FakeService routes on the system prompt, and this change appends section
    # context to it. The persona text the regex anchors on must survive.
    it "still routes to the duck branch of FakeService" do
      expect(
        service.duck_response(user, exercise, section: "code_review", message: "hi", thread: [])
      ).to eq(FakeService::DUCK_RESPONSE_TEXT)
    end
  end

  describe "#answer_follow_up sending real conversational turns" do
    let(:user) { User.create!(email: "follow-up@example.com", name: "FollowUp", skill_level: "developing", focus_areas: [], api_key: "fake", provider: "fake") }
    let(:exercise) do
      user.daily_exercises.create!(date: Date.current, language: "ruby_rails",
                                   problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_stringify_keys,
                                   generated_at: Time.current)
    end
    let(:daily_response) do
      user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
                                   answers: { "code_review" => "I think it is an N+1 query." },
                                   ai_review: { "code_review" => { "strengths" => [ "spotted the loop" ] } })
    end
    let(:service) { FakeService.new("fake") }

    def captured_call(thread:)
      captured = nil
      allow(service).to receive(:call).and_wrap_original do |original, **kwargs|
        captured = kwargs
        original.call(**kwargs)
      end
      service.answer_follow_up(user, exercise, daily_response,
                               section: "code_review", question: "why does that matter?", thread: thread)
      captured
    end

    it "maps stored rows straight onto history" do
      thread = [
        { role: "user",      content: "what did I miss?" },
        { role: "assistant", content: "the eager load" }
      ]

      kwargs = captured_call(thread: thread)

      expect(kwargs[:history]).to eq(thread)
      expect(kwargs[:prompt]).not_to include("Conversation so far:")
      expect(kwargs[:prompt]).not_to include("what did I miss?")
    end

    # Deliberately not cached, and not merely by omission: this prompt carries
    # the question and a review summary rather than the section's code, so it
    # lands well under the threshold the duck can reach. Measurements in
    # CLAUDE.md under "Conversational calls send real turns".
    it "does not ask for caching, unlike the duck" do
      expect(captured_call(thread: [])[:cache_system]).to be_falsey
    end

    it "moves the provider-authored question and review into system" do
      kwargs = captured_call(thread: [])

      expect(kwargs[:system]).to include(exercise.problem_set.dig("code_review", "question"))
      expect(kwargs[:prompt]).not_to include(exercise.problem_set.dig("code_review", "question"))
    end

    # The engineer's answer is the only free-form text they authored in this
    # call. Keeping it in the user turn is the point of the whole change — a
    # role boundary the user can write across is not a boundary, so their words
    # must never arrive carrying system authority.
    it "keeps the engineer's own answer in the user turn, never in system" do
      kwargs = captured_call(thread: [])

      expect(kwargs[:prompt]).to include(daily_response.answers["code_review"])
      expect(kwargs[:system]).not_to include(daily_response.answers["code_review"])
    end

    it "keeps the per-turn directive attached to the new turn" do
      kwargs = captured_call(thread: [])

      expect(kwargs[:prompt]).to include("why does that matter?")
      expect(kwargs[:prompt]).to include("Answer it directly.")
    end

    # FakeService routes on the system prompt, and this change appends context
    # to it. The persona text the regex anchors on must survive.
    it "still routes to the follow-up branch of FakeService" do
      expect(
        service.answer_follow_up(user, exercise, daily_response,
                                 section: "code_review", question: "hi", thread: [])
      ).to eq(FakeService::FOLLOW_UP_ANSWER_TEXT)
    end
  end

  describe ".for" do
    it "returns a ClaudeService for an anthropic user" do
      user.update!(api_key: "sk-ant-test", provider: "anthropic")
      expect(AiService.for(user)).to be_a(ClaudeService)
    end

    it "returns a GeminiService for a gemini user" do
      user.update!(api_key: "AIzaTest", provider: "gemini")
      expect(AiService.for(user)).to be_a(GeminiService)
    end

    it "raises AiService::Error when the user has no recognized provider" do
      expect { AiService.for(user) }.to raise_error(AiService::Error, /no recognized AI provider/)
    end
  end

  # One standard, seven prompts. Each example sends a request down one call
  # path and counts the standard in what reached the provider: zero means a
  # site lost it, two means a site both inlined and interpolated it.
  describe "the shared plain-language standard" do
    let(:standard) { AiService::PLAIN_LANGUAGE_STANDARD }

    # Class-level, because #review_sections builds a fresh service per thread.
    let(:recording_class) do
      calls = []
      Class.new(double_class) do
        define_singleton_method(:calls) { calls }

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil)
          self.class.calls << "#{system}\n#{prompt}"
          super
        end
      end
    end

    let(:exercise) do
      DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "Find the N+1", "snippet" => "code", "scenario" => "a billing job" }
      })
    end

    let(:reviewed_response) do
      DailyResponse.new(
        answers: { "code_review" => "Looks fine to me" },
        ai_review: { "code_review" => { "missed" => [ "The association is loaded per row" ] } }
      )
    end

    let(:reference) do
      ConceptReference.new(concept: "n_plus_one", language: "ruby_rails",
                           tagline: "t", explanation: "e", code_example: "c", senior_lens: "s")
    end

    def occurrences_per_call
      recording_class.calls.map { |sent| sent.scan(standard).size }
    end

    it "reaches the duck exactly once" do
      recording_class.new(canned_text: "A guiding question.")
        .duck_response(user, exercise, section: "code_review", message: "help", thread: [])

      expect(occurrences_per_call).to eq([ 1 ])
    end

    it "reaches the concept reference prompt exactly once" do
      json = { tagline: "t", explanation: "e", code_example: "c", senior_lens: "s" }.to_json
      recording_class.new(canned_text: json).generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(occurrences_per_call).to eq([ 1 ])
    end

    it "reaches the concept reframing exactly once" do
      recording_class.new(canned_text: "Another angle.").explain_concept_differently(user, reference)

      expect(occurrences_per_call).to eq([ 1 ])
    end

    it "reaches the feedback reframing exactly once" do
      recording_class.new(canned_text: "Another angle.")
        .explain_differently(user, exercise, reviewed_response, section: "code_review", prior_alternates: [])

      expect(occurrences_per_call).to eq([ 1 ])
    end

    it "reaches the review follow-up exactly once" do
      recording_class.new(canned_text: "Because.")
        .answer_follow_up(user, exercise, reviewed_response, section: "code_review", question: "Why?", thread: [])

      expect(occurrences_per_call).to eq([ 1 ])
    end

    it "reaches the judge exactly once" do
      recording_class.new(canned_text: { status: "keep" }.to_json)
        .judge_section(user, ExerciseSection::CodeReview,
          { "question" => "Find the N+1", "snippet" => "code", "concept" => "n_plus_one" },
          rung: "senior", locked: false)

      expect(occurrences_per_call).to eq([ 1 ])
    end

    # The difficulty assessment rides the same fan-out and had no style rule
    # before, so it is pinned at zero: reaching it would be a new content
    # requirement rather than consolidation.
    it "reaches every grading call exactly once, and the difficulty assessment not at all" do
      saved = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "cr?", "snippet" => "code" },
          "pattern"     => { "title" => "P", "question" => "pat?" }
        }
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: saved, date: Date.current, submitted_at: Time.current,
        answers: { "code_review" => "a" * 20, "pattern" => "a" * 20 }
      )

      recording_class.new(canned_text: { "rating" => "solid" }.to_json)
        .review_sections(user, saved, response, sections: %w[code_review pattern])

      grading, assessing = recording_class.calls.partition { |sent| sent.include?("giving direct, specific feedback") }
      expect(grading.map { |sent| sent.scan(standard).size }).to eq([ 1, 1 ])
      expect(assessing.map { |sent| sent.scan(standard).size }).to eq([ 0 ])
    end

    it "replaced each site's own wording rather than sitting beside it" do
      expect(AiService::DUCK_SYSTEM_PROMPT).not_to match(/plain words|no jargon/i)

      recording_class.new(canned_text: "Because.")
        .answer_follow_up(user, exercise, reviewed_response, section: "code_review", question: "Why?", thread: [])
      json = { tagline: "t", explanation: "e", code_example: "c", senior_lens: "s" }.to_json
      recording_class.new(canned_text: json).generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(recording_class.calls.join).not_to match(/Be direct and concrete|unpack any jargon/)
    end

    # Nothing can interpolate into a Markdown file, so CLAUDE.md holds a second
    # copy of the list; this is what keeps the two from drifting apart.
    it "matches CLAUDE.md's Writing style section except for the second-person item" do
      section = Rails.root.join("CLAUDE.md").read[/^\*\*Writing style\.\*\*.*?(?=^\*\*Modular)/m]
      doc_bullets = section.scan(/^- (.+?)(?=\n\n|\n- )/m).map { |(bullet)| bullet.squish }
      standard_lines = standard.lines.map(&:strip)

      expect(doc_bullets).to eq(standard_lines.grep(/\A- /).map { |line| line.delete_prefix("- ") } - [ "Second person, direct address." ])
      standard_lines.grep(/\A(Avoid|Aim for|Calibration)/).each do |line|
        expect(section.squish).to include(line)
      end
    end
  end

  describe "#generate_concept_reference" do
    let(:valid_json) do
      {
        tagline:      "Avoid N+1 by eager loading.",
        explanation:  "An N+1 query loads a collection then queries again per row.",
        code_example: "User.includes(:posts).each { |u| u.posts.size }",
        senior_lens:  "Reach for includes when you iterate associations."
      }.to_json
    end

    it "returns the four reference fields as a hash" do
      service = double_class.new(canned_text: valid_json)
      result  = service.generate_concept_reference(user, "n_plus_one", "ruby_rails")
      expect(result).to include(
        "tagline", "explanation", "code_example", "senior_lens"
      )
      expect(result["tagline"]).to eq("Avoid N+1 by eager loading.")
    end

    # Reference, guide and ladder share one response with extended thinking on,
    # so READ_TIMEOUT (sized for short replies) under-times it silently,
    # since staying under READ_TIMEOUT keeps the call from ever being tagged
    # long_running, letting RETRY_TIMEOUT_GUARD retry a genuine timeout into
    # duplicate billed calls.
    it "uses CONCEPT_REFERENCE_READ_TIMEOUT rather than the base READ_TIMEOUT" do
      service = double_class.new(canned_text: valid_json)
      service.generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(service.last_read_timeout).to eq(AiService::CONCEPT_REFERENCE_READ_TIMEOUT)
      expect(AiService::CONCEPT_REFERENCE_READ_TIMEOUT).to be > AiService::READ_TIMEOUT
    end

    # The double above records what AiService asked for. These run each real
    # provider against a test adapter, so the request the retry guard sees is
    # what is asserted: the budget reaches the request, marks it long_running,
    # and a timeout is therefore final rather than retried into a second bill.
    { ClaudeService => ClaudeService::API_URL, GeminiService => GeminiService::API_URL }.each do |provider_class, url|
      it "takes a timed-out #{provider_class} call as final, on the dedicated budget, with one attempt" do
        attempts = []
        service  = provider_class.new("key")
        service.instance_variable_set(:@conn, Faraday.new do |f|
          f.request :retry, provider_class::RETRY_OPTIONS.merge(interval: 0, max_interval: 0)
          f.adapter :test do |stub|
            stub.post(url) do |env|
              attempts << [ env.request.timeout, env.request.context[:long_running] ]
              raise Faraday::TimeoutError, "Net::ReadTimeout"
            end
          end
        end)

        expect { service.generate_concept_reference(user, "n_plus_one", "ruby_rails") }.to raise_error(AiService::TimeoutError)
        expect(attempts).to eq([ [ AiService::CONCEPT_REFERENCE_READ_TIMEOUT, true ] ])
      end
    end

    it "logs usage with the generate_concept_reference purpose" do
      service = double_class.new(canned_text: valid_json)
      expect {
        service.generate_concept_reference(user, "n_plus_one", "ruby_rails")
      }.to change { ApiUsage.where(purpose: "generate_concept_reference").count }.by(1)
    end

    it "raises InvalidResponseError when the provider returns a non-object" do
      service = double_class.new(canned_text: "[1,2,3]")
      expect {
        service.generate_concept_reference(user, "n_plus_one", "ruby_rails")
      }.to raise_error(AiService::InvalidResponseError)
    end

    it "raises InvalidResponseError when a required field is missing" do
      partial = { tagline: "t", explanation: "e", code_example: "c" }.to_json # no senior_lens
      service = double_class.new(canned_text: partial)
      expect {
        service.generate_concept_reference(user, "n_plus_one", "ruby_rails")
      }.to raise_error(AiService::InvalidResponseError, /senior_lens/)
    end

    it "raises InvalidResponseError when a required field is blank" do
      blank = { tagline: "t", explanation: "e", code_example: "c", senior_lens: "   " }.to_json
      service = double_class.new(canned_text: blank)
      expect {
        service.generate_concept_reference(user, "n_plus_one", "ruby_rails")
      }.to raise_error(AiService::InvalidResponseError, /senior_lens/)
    end

    AiService::CONCEPT_REFERENCE_FIELDS.each do |field|
      [ nil, false, true, 0, 1.5, [], [ "prose" ], {}, { "text" => "prose" }, "", " \n\t " ].each do |invalid|
        it "rejects #{invalid.inspect} in required reference field #{field}" do
          payload = JSON.parse(valid_json).merge(field => invalid)
          service = double_class.new(canned_text: payload.to_json)

          expect {
            service.generate_concept_reference(user, "n_plus_one", "ruby_rails")
          }.to raise_error(AiService::InvalidResponseError, /#{field}/)
        end
      end

      it "preserves valid text verbatim in required reference field #{field}" do
        text = " \nValid reference prose.\t "
        payload = JSON.parse(valid_json).merge(field => text)
        service = double_class.new(canned_text: payload.to_json)

        expect(service.generate_concept_reference(user, "n_plus_one", "ruby_rails").fetch(field)).to eq(text)
      end
    end

    it "does not persist a row when a field is missing (job swallows, retries later)" do
      partial = { tagline: "t", explanation: "e", code_example: "c" }.to_json
      allow(AiService).to receive(:for).and_return(double_class.new(canned_text: partial))
      expect {
        GenerateConceptReferenceJob.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user.id)
      }.not_to change(ConceptReference, :count)
    end

    it "raises on an unsupported language rather than defaulting" do
      service = double_class.new(canned_text: valid_json)
      expect {
        service.generate_concept_reference(user, "n_plus_one", "mixed")
      }.to raise_error(AiService::Error, /Unsupported generation language/)
    end
  end

  describe "#build_exercise_prompt fourth-slot guidance" do
    it "renders the rolled fourth kind's guidance, not the other one's" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge, fourth: :plan_review)
      expect(prompt).to match(/PLAN REVIEW/)
      expect(prompt).not_to match(/AMBIGUITY HUNT/)
    end

    # Guidance and schema resolve their slots through the same ExerciseSection
    # .for_plan call, so a kind rolled into a slot it cannot occupy fails with
    # the same message either way rather than reaching a kind with no guidance
    # to give.
    it "refuses a kind rolled into a slot it cannot occupy, in either slot" do
      expect {
        service.send(:build_exercise_prompt, user, "ruby_rails", third: :plan_review)
      }.to raise_error(ArgumentError, /plan_review/)

      expect {
        service.send(:build_exercise_prompt, user, "ruby_rails", fourth: :challenge)
      }.to raise_error(ArgumentError, /challenge/)
    end

    it "names the fourth-slot concept needing reinforcement" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", fourth: :plan_review,
                            fourth_reinforcement: [ { concept: "scope_creep", bucket: "plan_review", tier: "standard" } ])
      expect(prompt).to include("scope_creep")
    end

    it "names a fourth-slot retention check as a previously mastered concept" do
      cm = user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", fourth: :plan_review, fourth_due_checks: [ cm ])
      expect(prompt).to match(/MASTERED/)
      expect(prompt).to include("scope_creep")
    end
  end

  describe "#generate_exercise threads the fourth slot through" do
    # The provider is given only the four sections the plan asked for: a
    # payload carrying a plan_review hash too would win fourth-slot precedence
    # and the assertion would hold no matter which kind was rolled.
    it "asks the provider for a fourth section matching the plan's rolled kind" do
      allow(DailyPlan).to receive(:for).and_call_original
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :ambiguity_hunt)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_call_original

      svc = double_class.new(canned_text: {
        "code_review" => { "question" => "q", "concept" => "n_plus_one" },
        "pattern"     => { "question" => "q", "concept" => "memoization" },
        "challenge"   => { "question" => "q", "concept" => "idempotency" },
        "ambiguity_hunt" => {
          "title" => "t", "scenario" => "s", "request" => "r",
          "planted_ambiguities" => [ "a", "b", "c", "d" ],
          "question" => "q", "concept" => "missing_success_criteria"
        }
      }.to_json)

      problem_set = svc.generate_exercise(user)

      expect(ExerciseSection.resolved_fourth_key(problem_set)).to eq("ambiguity_hunt")
      expect(svc.last_prompt).to include("\"ambiguity_hunt\"")
      expect(svc.last_prompt).not_to include("\"plan_review\"")
    end
  end
  # The whole point of assessing difficulty in its own pass is that the
  # assessor cannot see the engineer. These examples are that claim, made
  # executable: if someone later threads the response through for convenience,
  # they fail rather than quietly turning a content rating into a performance
  # (and therefore tier) readout.
  describe "difficulty assessment" do
    def loaded_day
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review"    => { "question" => "What is wrong here?", "snippet" => "Order.all.each { |o| o.user.name }" },
          "pattern"        => { "title" => "Memoize", "question" => "When would you cache this?" },
          "ambiguity_hunt" => { "title" => "Leaderboard", "request" => "Add a leaderboard.",
                                "question" => "What needs clarifying?",
                                "planted_ambiguities" => [ "AH-SECRET-ONE", "AH-SECRET-TWO" ] }
        }
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
        answers: { "code_review" => "ANSWER-SENTINEL-TEXT", "pattern" => "ANSWER-SENTINEL-TEXT",
                   "ambiguity_hunt" => "ANSWER-SENTINEL-TEXT" },
        section_ratings: { "code_review" => "too_hard", "pattern" => "too_easy" }
      )
      [ exercise, response ]
    end

    def difficulty_prompt(exercise, sections = %w[code_review pattern ambiguity_hunt])
      service.send(:build_difficulty_prompt, exercise, sections)
    end

    it "shows the assessor the problem exactly as the engineer sees it" do
      exercise, = loaded_day
      prompt = difficulty_prompt(exercise)

      expect(prompt).to include("What is wrong here?")
      expect(prompt).to include("Order.all.each { |o| o.user.name }")
      expect(prompt).to include("Add a leaderboard.")
    end

    # The named risk. ConceptMastery's tier is deliberately invisible to the
    # engineer; a difficulty rating derived from it would re-expose that signal
    # under a new name. Nothing tier-shaped can reach this prompt because
    # nothing tier-shaped is passed to the method that builds it.
    it "carries nothing about the engineer, their tier, or their history" do
      exercise, = loaded_day
      user.update!(name: "Ada Lovelace", skill_level: "beginner")
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :reduced)

      prompt = difficulty_prompt(exercise)

      expect(prompt).not_to include("Ada Lovelace")
      expect(prompt).not_to include("beginner")
      expect(prompt).not_to include("(reduced)")
      expect(prompt).not_to include("(standard)")
      expect(prompt).not_to include("n_plus_one")
    end

    # Assessed before it can be coloured by how well this particular engineer
    # did: a strong answer to a demanding problem is still demanding, and the
    # only way to guarantee that is to withhold the answer rather than ask for
    # it to be ignored.
    it "carries neither the answers nor the self-ratings" do
      exercise, = loaded_day
      prompt = difficulty_prompt(exercise)

      expect(prompt).not_to include("ANSWER-SENTINEL-TEXT")
      expect(prompt).not_to include("too_hard")
      expect(prompt).not_to include("too easy")
    end

    # Same rule the duck prompt lives under, and for the same reason — this
    # prompt is built from duck_section_context, so it inherits the exclusion
    # rather than restating it. Pinned anyway: the two callers sharing one
    # authority is exactly what a future edit could break silently.
    it "carries no answer key" do
      exercise, = loaded_day
      prompt = difficulty_prompt(exercise)

      expect(prompt).not_to include("AH-SECRET-ONE")
      expect(prompt).not_to include("AH-SECRET-TWO")
    end

    it "offers exactly the levels this app can store" do
      exercise, = loaded_day
      prompt = difficulty_prompt(exercise)

      DailyResponse::DIFFICULTY_LEVELS.each { |level| expect(prompt).to include(level) }
    end

    # A section that failed to grade has no review hash to attach an assessment
    # to, and one the day never asked about must not acquire one.
    it "merges an assessment into each successfully graded section" do
      exercise, response = loaded_day
      svc = assessing_class.new(
        review: { "rating" => "solid" },
        difficulty: {
          "code_review" => { "level" => "demanding", "reason" => "The n+1 hides inside an association call." },
          "pattern"     => { "level" => "straightforward", "reason" => "One thing to notice." },
          "challenge"   => { "level" => "moderate", "reason" => "Not asked about today." }
        }
      )

      results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern])

      expect(results["code_review"][:review]["difficulty"])
        .to eq("level" => "demanding", "reason" => "The n+1 hides inside an association call.")
      expect(results["pattern"][:review]["difficulty"]).to eq("level" => "straightforward", "reason" => "One thing to notice.")
      expect(results.keys).to match_array(%w[code_review pattern])
    end

    it "bills the assessment separately from the grading calls" do
      exercise, response = loaded_day
      svc = assessing_class.new(review: { "rating" => "solid" },
                                difficulty: { "code_review" => { "level" => "moderate", "reason" => "r" } })

      expect {
        svc.review_sections(user, exercise, response, sections: %w[code_review pattern])
      }.to change { ApiUsage.where(purpose: "assess_difficulty").count }.by(1)
        .and change { ApiUsage.where(purpose: "review_response").count }.by(2)
    end

    # The note is context for reading a review. It is never worth costing the
    # engineer the review itself, which they paid for with their own API key.
    it "leaves the grades intact when the assessment fails outright" do
      exercise, response = loaded_day
      svc = assessing_class.new(review: { "rating" => "solid" }, difficulty: :raise)

      results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern])

      expect(results["code_review"][:ok]).to be(true)
      expect(results["code_review"][:review]).not_to have_key("difficulty")
      expect(results["pattern"][:ok]).to be(true)
    end

    it "drops a level it has no way to render and a reason of the wrong type" do
      exercise, response = loaded_day
      svc = assessing_class.new(
        review: { "rating" => "solid" },
        difficulty: {
          "code_review" => { "level" => "brutal", "reason" => "Off-vocabulary." },
          "pattern"     => { "level" => "moderate", "reason" => [ "not", "a", "sentence" ] }
        }
      )

      results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern])

      expect(results["code_review"][:review]).not_to have_key("difficulty")
      expect(results["pattern"][:review]["difficulty"]).to eq("level" => "moderate", "reason" => "")
    end

    # The failure this guards cost the engineer everything at once: Thread#value
    # re-raises anything the assessment did not catch, ResponsesController#review
    # rescues only the AiService hierarchy, so a JSON::ParserError from a 200
    # with a non-JSON body — or a ConnectionTimeoutError from the extra pooled
    # checkout this pass adds — 500s a request whose grades had already
    # succeeded, discards them after billing, and leaves the review claim held.
    it "keeps the grades when the assessment raises something outside the AiService hierarchy" do
      exercise, response = loaded_day
      exploding_class = Class.new(assessing_class) do
        private

        def assess_difficulty(_user, _exercise, sections:)
          raise JSON::ParserError, "unexpected token"
        end
      end
      svc = exploding_class.new(review: { "rating" => "solid" })

      results = nil
      expect { results = svc.review_sections(user, exercise, response, sections: %w[code_review pattern]) }
        .not_to raise_error

      expect(results["code_review"][:ok]).to be(true)
      expect(results["pattern"][:ok]).to be(true)
      expect(results["code_review"][:review]).not_to have_key("difficulty")
    end

    # Passing any max_tokens is what turns extended thinking off in
    # ClaudeService, so this pins the cost model as much as the length: without
    # it the note runs with thinking on and the full generation budget, billed
    # to the engineer's own key.
    it "caps the assessment's output, which is also what disables thinking" do
      exercise, response = loaded_day
      caps = []
      capturing_class = Class.new(double_class) do
        define_method(:call) do |system:, prompt:, cache_system: false,
                                 read_timeout: AiService::READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil|
          caps << [ system.include?("rating how hard") ? :difficulty : :grade, max_tokens ]
          super(system: system, prompt: prompt, cache_system: cache_system,
                read_timeout: read_timeout, max_tokens: max_tokens, history: history, purpose: purpose)
        end
      end

      capturing_class.new(canned_text: { "rating" => "solid" }.to_json)
                     .review_sections(user, exercise, response, sections: %w[code_review])

      expect(caps).to include([ :difficulty, AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS ])
      expect(caps).to include([ :grade, nil ])
      expect(AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS).to be < ClaudeService::MAX_TOKENS
    end

    # Regression floor for #168: four-section calls hit the old cap on all four
    # runs, and truncation is swallowed, so the note vanished without an error.
    # 160 is the rounded per-section output observed there (319 tokens across
    # two sections).
    it "budgets at least 160 tokens per section a day can hold" do
      floor = ExerciseSection.slot_count * 160

      expect(AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS).to be >= floor
    end

    it "grows with the reason length a day's sections may use" do
      longest_valid_reasons = ExerciseSection.slot_count * DailyResponse::MAX_DIFFICULTY_REASON_LENGTH /
                              AiService::DIFFICULTY_ASSESSMENT_CHARS_PER_TOKEN

      expect(AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS).to be >= longest_valid_reasons
    end

    it "is an Integer, since both providers serialize it straight into the request" do
      expect(AiService::DIFFICULTY_ASSESSMENT_MAX_TOKENS).to be_an(Integer)
    end

    it "tells the model the reason's character limit" do
      exercise, = loaded_day
      prompt = difficulty_prompt(exercise)

      expect(prompt).to include("#{DailyResponse::MAX_DIFFICULTY_REASON_LENGTH} characters")
    end

    # Blocked on a queue rather than a sleep, so the example is deterministic and
    # does not spend the grace period in real time.
    #
    # Wrapped in Timeout because the regression this guards is a HANG, not a
    # wrong value: drop the bounded join and #review_sections waits on the
    # assessment forever. A hung example takes the whole CI job down with it and
    # says nothing about why, so the timeout converts that into a named failure.
    it "leaves without the note rather than letting a hung assessment hold the review" do
      exercise, response = loaded_day
      gate = Queue.new
      hanging_class = Class.new(assessing_class) do
        define_method(:assess_difficulty) { |_user, _exercise, sections:| gate.pop }
        private :assess_difficulty
      end
      svc = hanging_class.new(review: { "rating" => "solid" })

      stub_const("AiService::DIFFICULTY_ASSESSMENT_GRACE_SECONDS", 0.05)

      results = Timeout.timeout(10) do
        svc.review_sections(user, exercise, response, sections: %w[code_review])
      end

      expect(results["code_review"][:ok]).to be(true)
      expect(results["code_review"][:review]).not_to have_key("difficulty")
    ensure
      gate << {}
    end

    # The scale used to be three descriptions destructured off DIFFICULTY_LEVELS
    # positionally. Adding or reordering a level would have relabelled every
    # rung silently; these two pin the assumption the prompt still makes.
    it "has guidance for exactly the levels it can offer" do
      expect(AiService::DIFFICULTY_GUIDANCE.keys).to eq(DailyResponse::DIFFICULTY_LEVELS)
    end

    it "orders the vocabulary easiest first, which is what lets the prompt call .first easy" do
      expect(DailyResponse::DIFFICULTY_LEVELS).to eq(%w[straightforward moderate demanding])
    end

    it "bounds a runaway reason rather than rendering it whole" do
      exercise, response = loaded_day
      svc = assessing_class.new(
        review: { "rating" => "solid" },
        difficulty: { "code_review" => { "level" => "moderate", "reason" => "x" * 500 } }
      )

      results = svc.review_sections(user, exercise, response, sections: %w[code_review])

      expect(results["code_review"][:review]["difficulty"]["reason"].length)
        .to eq(DailyResponse::MAX_DIFFICULTY_REASON_LENGTH)
    end
  end

  describe "#generate_concept_reference guide fields" do
    let(:full_reference) do
      {
        "tagline" => "t", "explanation" => "e", "code_example" => "c", "senior_lens" => "s",
        "guide_plain_language" => "plain", "guide_worked_example" => "worked",
        "guide_pitfalls" => "pitfalls",
        "ladder_junior" => "j", "ladder_senior" => "s", "ladder_principal_engineer" => "p"
      }
    end

    it "asks for the guide fields in the same request as the reference" do
      service = double_class.new(canned_text: full_reference.to_json)
      service.generate_concept_reference(user, "n_plus_one", "ruby_rails")

      AiService::CONCEPT_GUIDE_FIELDS.each do |field|
        expect(service.last_prompt).to include(field)
      end
    end

    it "bills one call for both halves" do
      service = double_class.new(canned_text: full_reference.to_json)

      expect {
        service.generate_concept_reference(user, "n_plus_one", "ruby_rails")
      }.to change { ApiUsage.where(purpose: "generate_concept_reference").count }.by(1)
    end

    it "returns the guide fields alongside the reference fields" do
      result = double_class.new(canned_text: full_reference.to_json)
                           .generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(result).to include(*AiService::CONCEPT_GUIDE_FIELDS)
    end

    # The preserved-behavior assertion. A provider that writes a good reference
    # and flubs the guide used to succeed, and must keep succeeding — otherwise
    # a first-exposure inline dropdown that would have existed doesn't.
    # Do not weaken this to make a stricter validation pass.
    it "still succeeds when the provider omits the guide entirely" do
      legacy = { "tagline" => "t", "explanation" => "e", "code_example" => "c", "senior_lens" => "s" }

      expect {
        double_class.new(canned_text: legacy.to_json)
                    .generate_concept_reference(user, "n_plus_one", "ruby_rails")
      }.not_to raise_error
    end

    it "still raises when a reference field is missing" do
      missing_lens = full_reference.except("senior_lens")

      expect {
        double_class.new(canned_text: missing_lens.to_json)
                    .generate_concept_reference(user, "n_plus_one", "ruby_rails")
      }.to raise_error(AiService::InvalidResponseError, /senior_lens/)
    end

    it "normalizes a non-String guide value to nil" do
      malformed = full_reference.merge("guide_worked_example" => [ "not", "a", "string" ])

      result = double_class.new(canned_text: malformed.to_json)
                           .generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(result["guide_worked_example"]).to be_nil
    end

    it "normalizes an over-length guide value to nil" do
      too_long = full_reference.merge("guide_pitfalls" => "x" * (AiService::MAX_CONCEPT_GUIDE_LENGTH + 1))

      result = double_class.new(canned_text: too_long.to_json)
                           .generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(result["guide_pitfalls"]).to be_nil
    end

    it "normalizes a whitespace-only guide value to nil" do
      blank = full_reference.merge("guide_plain_language" => "   \n  ")

      result = double_class.new(canned_text: blank.to_json)
                           .generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(result["guide_plain_language"]).to be_nil
    end

    it "leaves a normal guide value untouched" do
      result = double_class.new(canned_text: full_reference.to_json)
                           .generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(result["guide_plain_language"]).to eq("plain")
      expect(result["guide_worked_example"]).to eq("worked")
      expect(result["guide_pitfalls"]).to eq("pitfalls")
    end

    it "asks for the ladder in the same request, with its grain example" do
      service = double_class.new(canned_text: full_reference.to_json)
      service.generate_concept_reference(user, "n_plus_one", "ruby_rails")

      AiService::CONCEPT_LADDER_FIELDS.each { |field| expect(service.last_prompt).to include(field) }
      expect(service.last_prompt).to include("composite index column order")
    end

    it "still succeeds when the provider omits the ladder" do
      result = double_class.new(canned_text: full_reference.except(*AiService::CONCEPT_LADDER_FIELDS).to_json)
                           .generate_concept_reference(user, "n_plus_one", "ruby_rails")

      expect(result.values_at(*AiService::CONCEPT_LADDER_FIELDS)).to all(be_nil)
    end

    # Matches the guide normalizer: a runaway rung is a flubbed ladder, not a
    # rung to cut short. The read side truncates separately.
    it "normalizes an unusable rung to nil" do
      [ [ "a list" ], "   ", "x" * (AiService::MAX_LADDER_RUNG_LENGTH + 1) ].each do |junk|
        result = double_class.new(canned_text: full_reference.merge("ladder_senior" => junk).to_json)
                             .generate_concept_reference(user, "n_plus_one", "ruby_rails")

        expect(result["ladder_senior"]).to be_nil
        expect(result["ladder_junior"]).to eq("j")
      end
    end
  end

  # CONCEPT_REFERENCE_FIELDS is what #explain_concept_differently sends as
  # "the reference they have already read". Widening it would change that
  # existing prompt, so this pins the two lists apart.
  describe "concept field constants" do
    it "keeps the guide out of the reference field list" do
      expect(AiService::CONCEPT_REFERENCE_FIELDS)
        .to eq(%w[tagline explanation code_example senior_lens])
      expect(AiService::CONCEPT_REFERENCE_FIELDS & AiService::CONCEPT_GUIDE_FIELDS).to be_empty
    end

    it "does not send the guide to the alternate-framing prompt" do
      reference = ConceptReference.create!(
        concept: "n_plus_one", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s",
        guide_plain_language: "PLAIN_MARKER", guide_worked_example: "WORKED_MARKER",
        guide_pitfalls: "PITFALLS_MARKER"
      )
      service = double_class.new(canned_text: "Another angle.")
      service.explain_concept_differently(user, reference)

      expect(service.last_prompt).not_to include("PLAIN_MARKER", "WORKED_MARKER", "PITFALLS_MARKER")
    end

    it "does not send the ladder to the alternate-framing prompt" do
      reference = ConceptReference.create!(
        concept: "caching", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s",
        ladder_junior: "JUNIOR_MARKER", ladder_senior: "SENIOR_MARKER", ladder_principal_engineer: "PRINCIPAL_MARKER"
      )
      service = double_class.new(canned_text: "Another angle.")
      service.explain_concept_differently(user, reference)

      expect(service.last_prompt).not_to include("JUNIOR_MARKER", "SENIOR_MARKER", "PRINCIPAL_MARKER")
    end
  end
end

RSpec.describe AiService, "drilled concepts in the generation prompt" do
  let(:user)    { User.create!(email: "prompt-drill@example.com", name: "Prompt") }
  let(:service) { FakeService.new("fake-key") }

  it "annotates a drilled entry apart from its tier and explains the annotation once" do
    prompt = service.send(:build_exercise_prompt, user,
                          reinforcement: [ { concept: "n_plus_one", bucket: "ruby_rails", tier: "reduced", drilled: true },
                                           { concept: "memoization", bucket: "ruby_rails", tier: "standard" } ])

    expect(prompt).to include("Concepts needing reinforcement right now: n_plus_one (reduced, drilled), memoization (standard)")
    expect(prompt).to include("Drilled concepts: a concept marked `drilled` is one the engineer asked to practise")
    expect(prompt).to include("`drilled` on its own never eases or raises anything")
  end

  it "annotates a drilled fourth-slot entry the same way" do
    prompt = service.send(:build_exercise_prompt, user, fourth: :plan_review,
                          fourth_reinforcement: [ { concept: "scope_creep", bucket: "plan_review", tier: "standard", drilled: true } ])

    expect(prompt).to include("Fourth-section (plan_review) concept needing reinforcement: scope_creep (standard, drilled)")
  end

  it "leaves the locked-kind line to override easing for whichever concept it carries" do
    user.update!(section_kind_levels: { "code_review" => "principal_engineer" }, locked_section_kinds: [ "code_review" ])
    prompt = service.send(:build_exercise_prompt, user,
                          reinforcement: [ { concept: "n_plus_one", bucket: "ruby_rails", tier: "reduced", drilled: true } ],
                          difficulty: KindDifficulty.for(user))

    expect(prompt).to include("Locked (code_review): for these sections, ignore the `(reduced)` easing rule")
    expect(prompt).to include("whichever concept they carry")
  end
end

RSpec.describe AiService, "generation prompt without feedback" do
  it "renders history without a Feedback fragment" do
    user = User.create!(email: "prompt-no-feedback@example.com", name: "Prompt")
    exercise = user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                                            problem_set: { "code_review" => { "concept" => "n_plus_one" } })
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                                 answers: { "code_review" => "x" * 20 }, concept_tags: { "code_review" => "n_plus_one" })

    prompt = FakeService.new("fake-key").send(:build_exercise_prompt, user)

    expect(prompt).not_to include("Feedback:")
  end
end

RSpec.describe AiService, "rung stamps on a generated set" do
  let(:user) { User.create!(email: "rung-stamp@example.com", name: "Rung", skill_level: "solid", provider: "fake", api_key: "fake-test-key") }

  it "stamps each section with its target when set, else the skill level's rung" do
    user.update!(section_kind_levels: { "code_review" => "principal_engineer" })

    problem_set = FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails")

    expect(problem_set["code_review"]["pitched_at"]).to eq("principal_engineer")
    expect(problem_set["pattern"]["pitched_at"]).to eq("senior")
  end

  it "marks a section eased when its concept was offered as reduced reinforcement in an unlocked kind" do
    concept = FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails").dig("code_review", "concept")
    user.concept_masteries.create!(concept: concept, language: "ruby_rails", tier: :reduced)
    allow(DailyPlan).to receive(:for).and_wrap_original do |m, *args, **kw|
      m.call(*args, **kw).with(reinforcement: [ { concept: concept, bucket: "ruby_rails", tier: "reduced" } ])
    end

    problem_set = FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails")

    expect(problem_set["code_review"]["eased"]).to be(true)
  end

  it "stamps a rung on every section the provider returned, so a slot won by precedence is not left blank" do
    problem_set = FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails")

    ExerciseSection.keys.select { |key| problem_set[key].is_a?(Hash) && problem_set[key].any? }.each do |key|
      expect(problem_set[key]["pitched_at"]).to eq("senior"), "#{key} carries no rung"
    end
  end

  it "does not mark a section eased when its kind is locked" do
    concept = FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails").dig("code_review", "concept")
    user.update!(section_kind_levels: { "code_review" => "senior" }, locked_section_kinds: [ "code_review" ])
    allow(DailyPlan).to receive(:for).and_wrap_original do |m, *args, **kw|
      m.call(*args, **kw).with(reinforcement: [ { concept: concept, bucket: "ruby_rails", tier: "reduced" } ])
    end

    problem_set = FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails")

    expect(problem_set["code_review"]).not_to have_key("eased")
  end
end

RSpec.describe AiService, "#judge_section" do
  let(:user) { User.create!(email: "judge@example.com", name: "J", provider: "fake", api_key: "fake-test-key") }
  let(:section) { { "question" => "What is wrong?", "snippet" => "code", "concept" => "n_plus_one", "teaching_note" => "hint", "pitched_at" => "senior" } }

  it "sends the section, its concept, rung, lock state and the kind's task, and never another section or history" do
    svc = FakeService.new("fake-key")
    captured = nil
    allow(svc).to receive(:call_and_log).and_wrap_original { |m, *args, **kw| captured = kw; m.call(*args, **kw) }

    svc.judge_section(user, ExerciseSection::CodeReview, section, rung: "senior", locked: true)

    expect(captured[:purpose]).to eq("judge_section")
    expect(captured[:max_tokens]).to eq(AiService::JUDGE_MAX_TOKENS)
    expect(captured[:system]).to include("checking one section of a generated coding exercise")
    expect(captured[:system]).to include("Never reject a problem for being hard.")
    expect(captured[:prompt]).to include("n_plus_one").and include("senior").and include("locked").and include(ExerciseSection::CodeReview.judge_task)
    expect(captured[:prompt]).not_to include("Recent performance")
    expect(captured.fetch(:history, [])).to eq([])
  end

  it "returns a parsed verdict" do
    expect(FakeService.new("fake-key").judge_section(user, ExerciseSection::CodeReview, section, rung: "senior", locked: false).status).to eq(:keep)
  end

  it "never sends the ambiguity hunt's answer key" do
    svc = FakeService.new("fake-key")
    captured = nil
    allow(svc).to receive(:call_and_log).and_wrap_original { |m, *args, **kw| captured = kw; m.call(*args, **kw) }
    hunt = { "request" => "Build a leaderboard", "question" => "q", "teaching_note" => "t", "concept" => "scope_creep", "planted_ambiguities" => [ "SECRET" ] }

    svc.judge_section(user, ExerciseSection::AmbiguityHunt, hunt, rung: "junior", locked: false)

    expect(captured[:prompt]).not_to include("SECRET")
  end

  # The stamps say the day eased this section, which real file it came from,
  # and that an earlier judgment rejected it — all of it about the author's
  # intent, which the judge is deliberately not told.
  it "never sends the server's own stamps, and still sends the current schema" do
    svc = FakeService.new("fake-key")
    captured = nil
    allow(svc).to receive(:call_and_log).and_wrap_original { |m, *args, **kw| captured = kw; m.call(*args, **kw) }
    stamped = section.merge("eased" => true, "source" => "excerpt-trace-id", "anchored" => true,
                            "current_schema" => "create_table :orders do |t|")

    svc.judge_section(user, ExerciseSection::CodeReview, stamped, rung: "senior", locked: false)

    ProblemSetIngest::SERVER_STAMPS.each { |stamp| expect(captured[:prompt]).not_to include(stamp) }
    expect(captured[:prompt]).not_to include("excerpt-trace-id")
    expect(captured[:prompt]).to include("create_table :orders")
  end
end

RSpec.describe AiService, "JUDGE_SYSTEM_PROMPT" do
  it "enumerates the rejection principles and issue types from JudgeVerdict's own constants" do
    expect(AiService::JUDGE_PRINCIPLE_GUIDANCE.keys).to eq(JudgeVerdict::PRINCIPLES)
    expect(AiService::JUDGE_SYSTEM_PROMPT).to include("Rejection principles, the only #{JudgeVerdict::PRINCIPLES.size}:")
    JudgeVerdict::PRINCIPLES.each do |principle|
      expect(AiService::JUDGE_SYSTEM_PROMPT).to include("- #{principle}: #{AiService::JUDGE_PRINCIPLE_GUIDANCE.fetch(principle)}")
    end
    expect(AiService::JUDGE_SYSTEM_PROMPT)
      .to include("Issues, the only #{JudgeVerdict::ISSUE_TYPES.size}: #{JudgeVerdict::ISSUE_TYPES.join(', ')}.")
  end
end

RSpec.describe AiService, "single-section retry prompt" do
  let(:user) { User.create!(email: "retry@example.com", name: "R") }
  it "renders one kind's schema and fixes the concept" do
    prompt = FakeService.new("fake-key").send(:build_exercise_prompt, user, "ruby_rails",
                                              third: :challenge, pattern: :pattern, fourth: :plan_review,
                                              only: ExerciseSection::Challenge, fixed_concept: "memoization")
    expect(prompt).to include('"challenge": {')
    expect(prompt).not_to include('"code_review": {')
    expect(prompt).to include("This section's concept must be exactly `memoization`")
  end
end

RSpec.describe AiService, "#generate_judged_exercise" do
  let(:user) { User.create!(email: "two-stage@example.com", name: "T", provider: "fake", api_key: "fake-test-key") }

  def verdict(hash, kind) = JudgeVerdict.parse(hash, kind: kind)

  # Both rolls pinned so every example runs the same four-kind, plain-snippet
  # day: a drop assertion needs the kind it drops to have been scheduled, and
  # a retention assertion needs code_review's concept to be hostable there.
  before do
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
    allow(WeightedRoll).to receive(:pick).and_call_original
    allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_return(:application_code)
    # Restored after the and_call_original above, which drops the suite-wide pin.
    allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:toy)
  end

  it "keeps a set the judge keeps, with every section still present and stamped" do
    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.dropped_sections).to eq([])
    expect(judged.problem_set.keys).to include("code_review", "pattern")
    expect(judged.outcomes.values).to all(include(status: :keep))
  end

  it "applies an edit to prose only" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      if kind == ExerciseSection::CodeReview
        verdict({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "x" } ],
                  "fields" => { "question" => "Tighter question" } }, kind)
      else
        verdict({ "status" => "keep" }, kind)
      end
    end

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.problem_set["code_review"]["question"]).to eq("Tighter question")
    expect(judged.problem_set["code_review"]["snippet"]).to include("loyalty_tier")
    expect(judged.outcomes["code_review"]).to include(status: :edit, issues: [ "padding" ])
  end

  # ProblemSetIngest stamps a grounded code_review's scenario itself — which
  # real file, and that the copy is altered — so an edit that rewrites it
  # would leave the page saying something untrue about deployed code.
  it "keeps ingest's scenario when an edit rewrites it on a grounded section" do
    allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:real)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless kind == ExerciseSection::CodeReview

      verdict({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "x" } ],
                "fields" => { "scenario" => "a shipping label printer", "question" => "Tighter question" } }, kind)
    end

    section = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails").problem_set["code_review"]

    expect(section["source"]).to be_present
    expect(section["scenario"]).to eq(RealSource.all.find { |excerpt| excerpt.id == section["source"] }.scenario)
    expect(section["question"]).to eq("Tighter question")
  end

  # The retry runs through the same ingest as the draft, so a grounded day's
  # retried code_review is stamped again — and the edit above can reach it.
  it "keeps ingest's scenario on a retried grounded section the judge then edits" do
    allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:real)
    calls = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless kind == ExerciseSection::CodeReview

      calls["code_review"] += 1
      if calls["code_review"] == 1
        verdict({ "status" => "reject", "principle" => "underdetermined", "evidence" => "x", "reason" => "r" }, kind)
      else
        verdict({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "x" } ],
                  "fields" => { "scenario" => "a shipping label printer", "question" => "Tighter question" } }, kind)
      end
    end

    section = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails").problem_set["code_review"]

    expect(section["source"]).to be_present
    expect(section["scenario"]).to eq(RealSource.all.find { |excerpt| excerpt.id == section["source"] }.scenario)
    expect(section["question"]).to eq("Tighter question")
  end

  it "applies an edit to an ungrounded section's scenario" do
    allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:toy)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless kind == ExerciseSection::CodeReview

      verdict({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "x" } ],
                "fields" => { "scenario" => "a shipping label printer" } }, kind)
    end

    section = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails").problem_set["code_review"]

    expect(section["source"]).to be_blank
    expect(section["scenario"]).to eq("a shipping label printer")
  end

  it "retries a rejected section once with the same concept, and keeps the retry when it passes" do
    calls = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      calls[kind.key] += 1
      if kind == ExerciseSection::CodeReview && calls["code_review"] == 1
        verdict({ "status" => "reject", "principle" => "underdetermined", "evidence" => "x", "reason" => "r" }, kind)
      else
        verdict({ "status" => "keep" }, kind)
      end
    end

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.dropped_sections).to eq([])
    expect(judged.outcomes["code_review"]).to include(status: :keep, retries: 1, dropped: false,
                                                      principle: "underdetermined", retry_principle: nil)
    expect(calls["code_review"]).to eq(2)
  end

  it "asks the retry for the same kind and the draft's concept when the draft concept is usable" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      kind == ExerciseSection::Challenge ? verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind) : verdict({ "status" => "keep" }, kind)
    end
    svc = FakeService.new("fake-key")
    prompts = []
    allow(svc).to receive(:call_and_log).and_wrap_original { |m, *args, **kw| prompts << kw[:prompt]; m.call(*args, **kw) }

    svc.generate_judged_exercise(user, language: "ruby_rails")

    expect(prompts.last).to include('"challenge": {').and include("This section's concept must be exactly `memoization`")
    expect(prompts.last).not_to include('"code_review": {')
  end

  it "drops a rejected section normalized to other without spending a retry call" do
    attempts = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      attempts[kind.key] += 1
      if kind == ExerciseSection::Challenge && attempts["challenge"] == 1
        verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind)
      else
        verdict({ "status" => "keep" }, kind)
      end
    end

    draft = FakeService::EXERCISE_PROBLEM_SET.deep_dup
    draft["challenge"]["concept"] = "invented_concept"

    generate_calls = 0
    svc = FakeService.new("fake-key")
    allow(svc).to receive(:call_and_log).and_wrap_original do |m, *args, **kw|
      if kw[:purpose] == "generate_exercise"
        generate_calls += 1
        { text: draft.to_json, input_tokens: 0, output_tokens: 0 }
      else
        m.call(*args, **kw)
      end
    end

    judged = svc.generate_judged_exercise(user, language: "ruby_rails")

    expect(generate_calls).to eq(1)
    expect(judged.dropped_sections).to eq([ "challenge" ])
    expect(judged.outcomes["challenge"]).to include(retries: 0, dropped: true, retry_principle: nil)
  end

  it "keeps a rejected code_review normalized to other as the anchor without spending a retry call" do
    attempts = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      attempts[kind.key] += 1
      if kind == ExerciseSection::CodeReview && attempts["code_review"] == 1
        verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind)
      else
        verdict({ "status" => "keep" }, kind)
      end
    end

    draft = FakeService::EXERCISE_PROBLEM_SET.deep_dup
    draft["code_review"]["concept"] = "invented_concept"

    generate_calls = 0
    svc = FakeService.new("fake-key")
    allow(svc).to receive(:call_and_log).and_wrap_original do |m, *args, **kw|
      if kw[:purpose] == "generate_exercise"
        generate_calls += 1
        { text: draft.to_json, input_tokens: 0, output_tokens: 0 }
      else
        m.call(*args, **kw)
      end
    end

    judged = svc.generate_judged_exercise(user, language: "ruby_rails")

    expect(generate_calls).to eq(1)
    expect(judged.dropped_sections).to eq([])
    expect(judged.problem_set["code_review"]["anchored"]).to be(true)
    expect(judged.outcomes["code_review"]).to include(retries: 0, dropped: false, fallback: "anchor", retry_principle: nil)
  end

  it "skips retry for other on a javascript day too" do
    attempts = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      attempts[kind.key] += 1
      if kind == ExerciseSection::Challenge && attempts["challenge"] == 1
        verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind)
      else
        verdict({ "status" => "keep" }, kind)
      end
    end

    draft = FakeService::EXERCISE_PROBLEM_SET.deep_dup
    draft["challenge"]["concept"] = "invented_concept"

    prompts = []
    generate_calls = 0
    svc = FakeService.new("fake-key")
    allow(svc).to receive(:call_and_log).and_wrap_original do |m, *args, **kw|
      if kw[:purpose] == "generate_exercise"
        generate_calls += 1
        prompts << kw[:prompt]
        { text: draft.to_json, input_tokens: 0, output_tokens: 0 }
      else
        m.call(*args, **kw)
      end
    end

    judged = svc.generate_judged_exercise(user, language: "javascript")

    expect(generate_calls).to eq(1)
    expect(prompts.one?).to be(true)
    expect(prompts.first).not_to include("This section's concept must be exactly")
    expect(judged.dropped_sections).to eq([ "challenge" ])
  end

  it "drops a section rejected twice, records the principle, and never loops" do
    calls = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      calls[kind.key] += 1
      kind == ExerciseSection::Pattern ? verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind) : verdict({ "status" => "keep" }, kind)
    end

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.dropped_sections).to eq([ "pattern" ])
    expect(judged.problem_set).not_to have_key("pattern")
    expect(judged.outcomes["pattern"]).to include(status: :reject, principle: "scope_mismatch", retries: 1, dropped: true)
    expect(calls["pattern"]).to eq(2)
  end

  it "keeps draft ingestion unchanged and prunes the judged set through ProblemSetIngest" do
    ingest_calls = []
    allow(ProblemSetIngest).to receive(:prune_to_expected_keys).and_call_original
    allow(ProblemSetIngest).to receive(:call).and_wrap_original do |m, *args, **kw|
      ingest_calls << kw.slice(:expected_keys, :fixed_concepts)
      m.call(*args, **kw)
    end

    FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    draft_calls = ingest_calls.select { |kw| kw[:fixed_concepts].blank? && kw[:expected_keys].size > 1 }

    expect(ProblemSetIngest).to have_received(:prune_to_expected_keys)
      .with(instance_of(Hash), expected_keys: %w[code_review pattern challenge plan_review])
    expect(draft_calls).to eq([ { expected_keys: %w[code_review pattern challenge plan_review] } ])
  end

  it "does not replay ingest on an already-built judged parsons_problem set" do
    allow(DailyPlan).to receive(:for).and_wrap_original do |m, *args, **kw|
      m.call(*args, **kw).with(third: :parsons_problem)
    end
    allow_any_instance_of(FakeService).to receive(:judge_section) { |_, _, kind, _section, **| verdict({ "status" => "keep" }, kind) }

    ingest_orders = []
    allow(ProblemSetIngest).to receive(:call).and_wrap_original do |m, *args, **kw|
      result = m.call(*args, **kw)
      if kw[:expected_keys] == %w[code_review pattern parsons_problem plan_review]
        ingest_orders << result.problem_set.dig("parsons_problem", "display_order")&.dup
      end
      result
    end

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(ingest_orders).to eq([ judged.problem_set.dig("parsons_problem", "display_order") ])
  end

  it "prunes unplanned extras before a dropped third can expose one as delivered" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      kind == ExerciseSection::Challenge ? verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind) : verdict({ "status" => "keep" }, kind)
    end

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")
    exercise = DailyExercise.new(problem_set: judged.problem_set, language: "ruby_rails", generated_at: Time.current, date: Date.current)

    expect(judged.dropped_sections).to eq([ "challenge" ])
    expect(judged.problem_set.keys).to contain_exactly("code_review", "pattern", "plan_review")
    expect(exercise.active_section_keys).to eq(%w[code_review pattern plan_review])
  end

  # Serially, each rejection costs a full generation plus a re-judge, so three
  # of them would run far past the single generation this path replaced.
  it "resolves two rejections at once rather than one after the other" do
    calls = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless [ ExerciseSection::Pattern, ExerciseSection::Challenge ].include?(kind)

      calls[kind.key] += 1
      if calls[kind.key] == 1
        verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind)
      else
        verdict({ "status" => "keep" }, kind)
      end
    end
    entered = Queue.new
    release = Queue.new
    allow_any_instance_of(FakeService).to receive(:retry_section) do |_, _user, _language, _draft, kind, _concept|
      entered << kind.key
      release.pop
      FakeService::EXERCISE_PROBLEM_SET[kind.key].deep_dup
    end

    judged = nil
    runner = Thread.new { judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails") }
    # Both retries are inside retry_section before either has been allowed to
    # return, which a serial loop cannot reach.
    both = Timeout.timeout(20) { [ entered.pop, entered.pop ] }
    2.times { release << :go }
    runner.join(30)

    expect(both).to contain_exactly("pattern", "challenge")
    expect(judged.dropped_sections).to eq([])
    expect(calls).to eq("pattern" => 2, "challenge" => 2)
  end

  it "asks a single-section retry for a tighter read budget than a whole day's draft" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      kind == ExerciseSection::Pattern ? verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind) : verdict({ "status" => "keep" }, kind)
    end
    timeouts = {}
    allow_any_instance_of(FakeService).to receive(:call_and_log).and_wrap_original do |m, *args, **kw|
      if %w[generate_exercise retry_section].include?(kw[:purpose])
        timeouts[kw[:purpose]] = kw[:read_timeout]
      end
      m.call(*args, **kw)
    end

    FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(timeouts).to eq(
      "generate_exercise" => AiService::GENERATION_READ_TIMEOUT,
      "retry_section"     => AiService::RETRY_READ_TIMEOUT
    )
    expect(AiService::RETRY_READ_TIMEOUT).to be < AiService::GENERATION_READ_TIMEOUT
  end

  it "records a retry separately from the initial draft" do
    calls = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless kind == ExerciseSection::Pattern

      calls[kind.key] += 1
      if calls[kind.key] == 1
        verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind)
      else
        verdict({ "status" => "keep" }, kind)
      end
    end

    expect {
      FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")
    }.to change { ApiUsage.where(purpose: "retry_section").count }.by(1)
      .and change { ApiUsage.where(purpose: "generate_exercise").count }.by(1)
  end

  # Nothing else distinguishes an anchored section: the outcomes hash the
  # marker used to live in is discarded once the day is written.
  it "stamps the anchored code_review, and stamps nothing on an ordinary section" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless kind == ExerciseSection::CodeReview

      verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind)
    end

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.problem_set["code_review"]["anchored"]).to be(true)
    expect(judged.problem_set["pattern"]).not_to have_key("anchored")
  end

  # Time.zone is thread-isolated, so a judge thread left on UTC would date its
  # usage row a day away from the generation it belongs to.
  it "dates every judge thread's usage row in the user's own zone" do
    user.update!(time_zone: "Auckland")

    travel_to Time.utc(2026, 9, 25, 22, 30) do
      Time.use_zone("Auckland") do
        FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")
      end
    end

    dates = user.api_usages.where(purpose: %w[generate_exercise judge_section]).distinct.pluck(:date)
    expect(user.api_usages.where(purpose: "judge_section").count).to be > 0
    expect(dates).to eq([ Date.new(2026, 9, 26) ])
  end

  # The day is built around code_review and an empty set fails DailyExercise's
  # presence validation, which would escape the batch job's per-user rescue.
  it "keeps a twice-rejected code_review as the day's anchor rather than dropping it" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless kind == ExerciseSection::CodeReview

      verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind)
    end

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.dropped_sections).to eq([])
    expect(judged.problem_set["code_review"]).to be_present
    expect(judged.outcomes["code_review"]).to include(dropped: false, fallback: "anchor", retries: 1,
                                                      principle: "scope_mismatch", retry_principle: "scope_mismatch")
  end

  it "keeps the drafted code_review when its retry generation fails" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      kind == ExerciseSection::CodeReview ? verdict({ "status" => "reject", "principle" => "underdetermined", "evidence" => "x", "reason" => "r" }, kind) : verdict({ "status" => "keep" }, kind)
    end
    svc = FakeService.new("fake-key")
    drafted = false
    allow(svc).to receive(:call_and_log).and_wrap_original do |m, *args, **kw|
      raise AiService::RateLimitError, "slow down" if drafted

      drafted = true
      m.call(*args, **kw)
    end
    allow(Rails.logger).to receive(:warn)

    judged = svc.generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.dropped_sections).to eq([])
    expect(judged.problem_set["code_review"]["question"]).to eq(FakeService::EXERCISE_PROBLEM_SET["code_review"]["question"])
    expect(judged.outcomes["code_review"]).to include(dropped: false, fallback: "anchor", retries: 0, retry_principle: nil)
  end

  it "keeps the draft's principle on a dropped section and records the retry's own verdict separately" do
    calls = Hash.new(0)
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless kind == ExerciseSection::Pattern

      calls["pattern"] += 1
      if calls["pattern"] == 1
        verdict({ "status" => "reject", "principle" => "scope_mismatch", "evidence" => "x", "reason" => "r" }, kind)
      else
        verdict({ "status" => "reject", "principle" => "underdetermined", "evidence" => "y", "reason" => "r2" }, kind)
      end
    end

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.outcomes["pattern"]).to include(status: :reject, principle: "scope_mismatch",
                                                  retry_principle: "underdetermined", issues: [], retries: 1, dropped: true)
  end

  it "drops a rejected section whose retry generation fails, without raising" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      kind == ExerciseSection::Pattern ? verdict({ "status" => "reject", "principle" => "underdetermined", "evidence" => "x", "reason" => "r" }, kind) : verdict({ "status" => "keep" }, kind)
    end
    svc = FakeService.new("fake-key")
    drafted = false
    allow(svc).to receive(:call_and_log).and_wrap_original do |m, *args, **kw|
      raise AiService::RateLimitError, "slow down" if drafted
      drafted = true
      m.call(*args, **kw)
    end
    allow(Rails.logger).to receive(:warn)
    expect(Rails.logger).to receive(:warn).with(/judge_retry_failed/).at_least(:once)

    judged = svc.generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.dropped_sections).to eq([ "pattern" ])
    expect(judged.outcomes["pattern"]).to include(retries: 0, dropped: true, retry_principle: nil)
  end

  it "keeps the draft unedited and logs a fallback when the judge fails or answers invalidly" do
    allow_any_instance_of(FakeService).to receive(:judge_section).and_raise(AiService::TimeoutError, "slow")
    allow(Rails.logger).to receive(:warn)
    expect(Rails.logger).to receive(:warn).with(/judge_fallback/).at_least(:once)

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.dropped_sections).to eq([])
    expect(judged.outcomes.values).to all(include(fallback: "timeout", status: :keep))
    expect(judged.problem_set["code_review"]["question"]).to eq(FakeService::EXERCISE_PROBLEM_SET["code_review"]["question"])
  end

  it "keeps the draft unedited when the judge answers outside its vocabulary" do
    allow_any_instance_of(FakeService).to receive(:judge_section).and_raise(JudgeVerdict::Invalid, "unknown status")
    allow(Rails.logger).to receive(:warn)

    judged = FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")

    expect(judged.outcomes.values).to all(include(fallback: "invalid_output"))
  end

  it "records a dropped section's planned concept as unhosted in the retention log" do
    concept = FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails").dig("pattern", "concept")
    user.concept_masteries.create!(concept: concept, language: "ruby_rails", tier: :standard, mastered_at: 1.month.ago,
                                   retention_interval_days: 7, next_retention_check_on: Date.current - 3)
    allow(user).to receive(:concepts_needing_reinforcement).and_return([])
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      kind == ExerciseSection::Pattern ? verdict({ "status" => "reject", "principle" => "reasoning_failure", "evidence" => "x", "reason" => "r" }, kind) : verdict({ "status" => "keep" }, kind)
    end

    expect(Rails.logger).to receive(:info).with(/\[retention\].*dropped=pattern:#{concept}/).at_least(:once)
    allow(Rails.logger).to receive(:info).and_call_original

    FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")
  end

  it "names the judge's outcomes and the unhosted planned concept in the diagnostics payload" do
    concept = FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails").dig("pattern", "concept")
    user.concept_masteries.create!(concept: concept, language: "ruby_rails", tier: :standard, mastered_at: 1.month.ago,
                                   retention_interval_days: 7, next_retention_check_on: Date.current - 3)
    allow(user).to receive(:concepts_needing_reinforcement).and_return([])
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      kind == ExerciseSection::Pattern ? verdict({ "status" => "reject", "principle" => "reasoning_failure", "evidence" => "x", "reason" => "r" }, kind) : verdict({ "status" => "keep" }, kind)
    end
    logged = nil
    allow(Rails.logger).to receive(:info) do |msg|
      logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
    end

    FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")
    payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))

    expect(payload["judge"]["pattern"]).to include("status" => "reject", "dropped" => true, "principle" => "reasoning_failure")
    expect(payload["judge"]["pattern"]["latency_ms"]).to be_a(Integer)
    expect(payload["unhosted"]).to include("section" => "pattern", "concept" => concept, "planned_as" => "retention")
    expect(payload["delivered"]).not_to have_key("pattern")
  end

  # A rejection rate says how often; only the quoted text says on what.
  it "records what a rejection was about in the diagnostics payload" do
    allow_any_instance_of(FakeService).to receive(:judge_section) do |_, _, kind, _section, **|
      next verdict({ "status" => "keep" }, kind) unless kind == ExerciseSection::Pattern

      verdict({ "status" => "reject", "principle" => "reasoning_failure",
                "evidence" => "the question names the missing index", "reason" => "It says where to look." }, kind)
    end
    logged = nil
    allow(Rails.logger).to receive(:info) do |msg|
      logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
    end

    FakeService.new("fake-key").generate_judged_exercise(user, language: "ruby_rails")
    payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))

    expect(payload["judge"]["pattern"]).to include("evidence" => "the question names the missing index",
                                                   "reason" => "It says where to look.")
  end

  it "leaves the single-stage path's diagnostics without a judge" do
    logged = nil
    allow(Rails.logger).to receive(:info) do |msg|
      logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
    end

    FakeService.new("fake-key").generate_exercise(user, language: "ruby_rails")
    payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))

    expect(payload["judge"]).to be_nil
    expect(payload["unhosted"]).to eq([])
  end
end
