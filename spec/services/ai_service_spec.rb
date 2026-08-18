require "rails_helper"

RSpec.describe AiService do
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  describe "request timeout budget" do
    # #review claims the row for REVIEW_CLAIM_STALE_AFTER and only then lets a
    # retry through. Sections are reviewed in parallel threads, so one section's
    # worst case is the whole request's: every attempt timing out, plus the
    # retry backoff between them. If that can exceed the claim window, a second
    # review can start while the first is still running — so this asserts the
    # two constants stay in a safe relationship rather than drifting apart.
    it "cannot exceed the review claim window even when every attempt times out" do
      retries = ClaudeService::RETRY_OPTIONS[:max]
      backoff = (0..retries).sum { |i| ClaudeService::RETRY_OPTIONS[:interval] * (ClaudeService::RETRY_OPTIONS[:backoff_factor]**i) }
      backoff *= (1 + ClaudeService::RETRY_OPTIONS[:interval_randomness])
      worst_case = (retries + 1) * (AiService::OPEN_TIMEOUT + AiService::READ_TIMEOUT) + backoff

      expect(worst_case).to be < ResponsesController::REVIEW_CLAIM_STALE_AFTER.to_i
    end

    # The review budget above is driven by #review holding a request thread and
    # a claim on the row. Generation shares neither constraint: it is always
    # enqueued (GenerateDailyExercisesJob), so it runs on the worker and holds
    # no claim. It is also the single largest response we ever ask for — one
    # non-streaming call carrying every section — against a model that thinks
    # before it answers, so nothing arrives on the socket for far longer than a
    # per-section review takes. Sharing READ_TIMEOUT with the review path made
    # every morning's generation die on Net::ReadTimeout.
    it "gives generation a budget far larger than the per-review one" do
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
      def self.read_timeouts
        @read_timeouts ||= []
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

      def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil)
        @last_read_timeout = read_timeout
        @last_max_tokens   = max_tokens
        @last_prompt       = prompt
        self.class.read_timeouts << read_timeout
        { text: @canned_text, input_tokens: @input_tokens, output_tokens: @output_tokens, truncated: @truncated }
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
    it "is a frozen 38-entry vocabulary" do
      expect(AiService::RAILS_CONCEPTS.size).to eq(38)
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
    it "is a frozen 40-entry vocabulary" do
      expect(AiService::JS_CONCEPTS.size).to eq(40)
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
      expect(prompt).to include("(reduced)")            # from the guidance text
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
    it "logs what was requested and what was delivered on every generation" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      set = full_problem_set("code_review" => { "concept" => "memoization", "title" => "t", "question" => "q" })
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([ { concept: "n_plus_one", tier: "reduced" } ])

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
      expect(payload["requested"]["reinforcement"]).to eq([ { "concept" => "n_plus_one", "tier" => "reduced" } ])
      expect(payload["requested"]).to have_key("due_checks")
      expect(payload["requested"]).to have_key("established")
      expect(payload["requested"]).to have_key("recent_performance")
      expect(payload["requested"]["pattern"]).to eq("pattern")
      expect(payload["requested"]["third"]).to eq("challenge")
      expect(payload["requested"]["fourth"]).to eq("plan_review")
      expect(payload["requested"]["section_count"]).to eq(4)
      expect(payload["delivered"]).to eq(JSON.parse(set.to_json))
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
  end

  describe "#build_review_day_context" do
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

    # DailyExercisesController#regenerate still generates inline, so this call
    # holds a Puma thread with a user waiting on the response. It needs more
    # room than a section review and much less than the worker's.
    it "tightens the budget when a request thread is blocked on the call" do
      svc = double_class.new(canned_text: full_problem_set.to_json)
      svc.generate_exercise(user, blocking: true)

      expect(svc.last_read_timeout).to eq(AiService::SYNC_GENERATION_READ_TIMEOUT)
    end

    it "keeps the blocking budget between the review and worker budgets" do
      expect(AiService::SYNC_GENERATION_READ_TIMEOUT).to be > AiService::READ_TIMEOUT
      expect(AiService::SYNC_GENERATION_READ_TIMEOUT).to be < AiService::GENERATION_READ_TIMEOUT
    end

    it "leaves a section review on the short request-thread budget" do
      exercise, response = exercise_and_response_for_review
      review = { "rating" => "solid", "correct" => [], "missed" => [], "better_questions" => [], "next_step" => "", "improved_code" => "" }
      svc = double_class.new(canned_text: review.to_json)

      svc.review_sections(user, exercise, response, sections: %w[code_review])

      expect(double_class.read_timeouts).to eq([ AiService::READ_TIMEOUT ])
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

    it "tags a failed section without affecting a successful one" do
      exercise, response = exercise_and_response

      failing_class = Class.new(AiService) do
        def initialize(_api_key = nil, canned_text: "{}")
          @canned_text = canned_text
          @calls = 0
        end

        private

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil)
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

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil)
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
        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil) = raise(AiService::AuthenticationError, "bad key")
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
        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil)
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
        attr_reader :last_prompt
        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil)
          @last_prompt = prompt
          super
        end
      end
      svc = spy_class.new(canned_text: "Because the database round-trip dominates.")

      result = svc.answer_follow_up(user, exercise, resp, section: "code_review",
                                    question: "Does eager loading always help?", thread: thread)

      expect(result).to eq("Because the database round-trip dominates.")
      expect(svc.last_prompt).to include("Does eager loading always help?")
      expect(svc.last_prompt).to include("loads per row")
      expect(svc.last_prompt).to include("Why is that slow?")
      expect(svc.last_prompt).to include("Each row triggers its own query.")
      expect(svc.last_prompt.index("Why is that slow?")).to be < svc.last_prompt.index("Each row triggers its own query.")
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

  describe "#duck_response" do
    let(:exercise) do
      DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "Find the N+1", "snippet" => "code", "scenario" => "a billing job" }
      })
    end

    # Local spy: the shared `double_class`'s `#call` doesn't expose `system:`,
    # and #duck_response has no `daily_response` argument to read a draft
    # answer from in the first place — this class exists purely to capture
    # both prompt strings this describe block's examples need to inspect.
    let(:duck_spy_class) do
      Class.new(double_class) do
        attr_reader :last_prompt, :last_system

        def call(system:, prompt:, cache_system: false, read_timeout: AiService::READ_TIMEOUT, max_tokens: nil)
          @last_system = system
          @last_prompt = prompt
          super
        end
      end
    end

    it "sends the section's question/scenario/snippet, the prior thread in order, and the new message" do
      thread = [
        { role: "user",      content: "What's slow here?" },
        { role: "assistant", content: "What happens inside that loop on each iteration?" }
      ]
      svc = duck_spy_class.new(canned_text: "What would change if the list had a thousand rows instead of ten?")

      result = svc.duck_response(user, exercise, section: "code_review",
                                 message: "I don't see anything wrong", thread: thread)

      expect(result).to eq("What would change if the list had a thousand rows instead of ten?")
      expect(svc.last_prompt).to include("Find the N+1")
      expect(svc.last_prompt).to include("a billing job")
      expect(svc.last_prompt).to include("What's slow here?")
      expect(svc.last_prompt).to include("I don't see anything wrong")
      expect(svc.last_prompt.index("What's slow here?")).to be < svc.last_prompt.index("I don't see anything wrong")
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

    # An explanation plus a concrete analogy does not fit in 150 tokens. The
    # ceiling stays a budget, not an enforcement mechanism — the prompt is
    # what actually withholds the answer.
    it "gives a reply room for an explanation while staying far below a review's ceiling" do
      expect(AiService::DUCK_RESPONSE_MAX_TOKENS).to eq(250)
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

        expect(svc.last_prompt).to include("def a")
        expect(svc.last_prompt).to include("work")
      end

      it "sends them in the learner's on-screen order, never the stored correct order" do
        svc = duck_spy_class.new(canned_text: "Which block has to run first?")

        svc.duck_response(user, parsons_exercise, section: "parsons_problem", message: "stuck", thread: [])

        expect(svc.last_prompt).to include("1. end")
        expect(svc.last_prompt).to include("2. def a")
        expect(svc.last_prompt).to include("3.   work")
        expect(svc.last_prompt).to match(/NOT the correct order/)
        expect(svc.last_prompt.index("1. end")).to be < svc.last_prompt.index("2. def a")
      end

      it "never emits the stored (solved) order when display_order is missing" do
        exercise_without_order = DailyExercise.new(language: "ruby_rails", problem_set: {
          "parsons_problem" => { "question" => "Arrange", "blocks" => [ "def a", "  work", "end" ] }
        })
        svc = duck_spy_class.new(canned_text: "Which block has to run first?")

        svc.duck_response(user, exercise_without_order, section: "parsons_problem", message: "stuck", thread: [])

        # The blocks are still sent — the model needs the code — but with no
        # positions, since the only order available here is the answer.
        expect(svc.last_prompt).to include("def a")
        expect(svc.last_prompt).to include("order withheld")
        expect(svc.last_prompt).not_to include("1. def a")
        expect(svc.last_prompt).not_to match(/NOT the correct order/)
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

        expect(svc.last_prompt).to include("order withheld")
        expect(svc.last_prompt).not_to include("1. def a")
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

        expect(svc.last_prompt).to include("order withheld")
      end

      it "omits the blocks line entirely for a section that has no blocks" do
        svc = duck_spy_class.new(canned_text: "A guiding question.")

        svc.duck_response(user, exercise, section: "code_review", message: "help", thread: [])

        expect(svc.last_prompt).not_to include("NOT the correct order")
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

        expect(svc.last_prompt).to include("Cache the response for 300 seconds")
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

        expect(svc.last_prompt).to include("Add a leaderboard to the dashboard.")
      end

      it "never leaks planted_ambiguities — that is the hidden grading answer key" do
        svc = duck_spy_class.new(canned_text: "What would 'top' mean here — most sessions, most points?")

        svc.duck_response(user, ambiguity_hunt_exercise, section: "ambiguity_hunt", message: "stuck", thread: [])

        expect(svc.last_prompt).not_to include("Which metric ranks users is unstated")
        expect(svc.last_prompt).not_to include("Tie-breaking is unstated")
        expect(svc.last_prompt).not_to include("planted_ambiguities")
      end
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
                            fourth_reinforcement: [ { concept: "scope_creep", tier: "standard" } ])
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
end
