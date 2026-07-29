require "rails_helper"

RSpec.describe AiService do
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  # Minimal concrete subclass so AiService's shared logic can be exercised
  # without a real network call to any provider.
  let(:double_class) do
    Class.new(AiService) do
      def initialize(canned_text: "{}", input_tokens: 1, output_tokens: 1)
        @canned_text   = canned_text
        @input_tokens  = input_tokens
        @output_tokens = output_tokens
      end

      private

      def call(system:, prompt:)
        { text: @canned_text, input_tokens: @input_tokens, output_tokens: @output_tokens }
      end

      def build_connection
        nil
      end
    end
  end

  let(:service) { double_class.new }

  describe "#exercise_schema_for" do
    it "defines a teaching_note and a concept for each of the three sections, for any language" do
      %w[ruby_rails javascript].each do |language|
        schema = service.send(:exercise_schema_for, language)
        expect(schema.scan('"teaching_note"').size).to eq(3)
        expect(schema.scan('"concept"').size).to eq(3)
      end
    end

    it "labels code fields with Ruby/Rails for ruby_rails" do
      schema = service.send(:exercise_schema_for, "ruby_rails")
      expect(schema).to include("Ruby/Rails code")
    end

    it "labels code fields with JavaScript/React for javascript" do
      schema = service.send(:exercise_schema_for, "javascript")
      expect(schema).to include("JavaScript/React code")
    end

    it "defaults to ruby_rails when no language is given" do
      expect(service.send(:exercise_schema_for)).to eq(service.send(:exercise_schema_for, "ruby_rails"))
    end

    it "defines a scenario field for each of the three sections" do
      schema = service.send(:exercise_schema_for)
      expect(schema.scan(/"scenario"/).size).to eq(3)
    end

    it "defines an optional glossary array for each of the three sections" do
      schema = service.send(:exercise_schema_for)
      expect(schema.scan(/"glossary"/).size).to eq(3)
    end

    it "swaps in a glossary array for the architecture block too" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)
      architecture = JSON.parse(schema)["architecture"]
      expect(architecture).to have_key("glossary")
    end

    it "includes the challenge block by default (third: :challenge)" do
      schema = service.send(:exercise_schema_for, "ruby_rails")
      expect(schema).to include("\"challenge\"")
      expect(schema).to include("starter_code")
      expect(schema).not_to include("\"architecture\"")
    end

    it "swaps in the architecture block with options + tradeoffs when third: :architecture" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)
      expect(schema).to include("\"architecture\"")
      expect(schema).to include("\"options\"")
      expect(schema).to include("\"tradeoffs\"")
      expect(schema).not_to include("\"challenge\"")
      expect(schema).not_to include("starter_code")
    end

    it "caps the architecture scenario at 2-3 sentences and 2-3 constraints" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)
      expect(schema).to include("2-3 sentences")
      expect(schema).to include("2-3 concrete constraints")
      expect(schema).not_to include("team size")
    end

    it "caps the architecture question at one sentence" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)
      expect(schema).to include("ONE sentence")
    end

    it "no longer asks the model for a pattern.reference block" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :challenge)
      pattern = JSON.parse(schema)["pattern"]

      expect(pattern.keys).to contain_exactly(
        "title", "why", "question", "scenario", "teaching_note", "concept", "glossary"
      )
      expect(pattern).not_to have_key("reference")
    end
  end

  describe "architecture diagram generation" do
    it "asks for a Mermaid diagram in the architecture reference, with syntax constraints" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :architecture)

      expect(schema).to include("diagram")
      expect(schema).to match(/mermaid/i)
    end

    it "constrains the diagram to a narrow, parseable subset" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :architecture)

      expect(prompt).to match(/flowchart TD|graph LR/)
      expect(prompt).to match(/8 nodes|eight nodes/i)
      expect(prompt).to match(/empty string/i) # opting out is allowed
    end

    it "does not ask for a diagram on a challenge third" do
      schema = service.send(:exercise_schema_for, "ruby_rails", third: :challenge)
      expect(schema).not_to match(/mermaid/i)
    end
  end

  describe "#roll_third_section" do
    it "returns :architecture ~60% and :challenge ~40% (both reachable)" do
      allow(service).to receive(:rand).and_return(0.10)
      expect(service.send(:roll_third_section)).to eq(:architecture)
      allow(service).to receive(:rand).and_return(0.90)
      expect(service.send(:roll_third_section)).to eq(:challenge)

      # Boundary check: just under vs. just at/over the new 0.60 threshold.
      allow(service).to receive(:rand).and_return(0.59)
      expect(service.send(:roll_third_section)).to eq(:architecture)
      allow(service).to receive(:rand).and_return(0.60)
      expect(service.send(:roll_third_section)).to eq(:challenge)
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
    it "is a frozen 18-entry vocabulary" do
      expect(AiService::RAILS_CONCEPTS.size).to eq(18)
      expect(AiService::RAILS_CONCEPTS).to be_frozen
      expect(AiService::RAILS_CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end

    it "includes the two Rails security concepts chosen for real depth" do
      expect(AiService::RAILS_CONCEPTS).to include("mass_assignment_protection", "sql_injection_prevention")
    end

    it "excludes secure_secrets_handling and dependency_vulnerability_management as poor fits for this app's format" do
      expect(AiService::RAILS_CONCEPTS).not_to include("secure_secrets_handling", "dependency_vulnerability_management")
    end
  end

  describe "JS_CONCEPTS" do
    it "is a frozen 20-entry vocabulary" do
      expect(AiService::JS_CONCEPTS.size).to eq(20)
      expect(AiService::JS_CONCEPTS).to be_frozen
      expect(AiService::JS_CONCEPTS).to include("closures", "prototype_chain", "hooks_dependencies")
    end

    it "includes the two JS security concepts chosen for real depth" do
      expect(AiService::JS_CONCEPTS).to include("xss_prevention", "insecure_client_storage")
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

  describe "ARCHITECTURE_CONCEPTS" do
    it "is a frozen 13-entry language-independent vocabulary" do
      expect(AiService::ARCHITECTURE_CONCEPTS.size).to eq(13)
      expect(AiService::ARCHITECTURE_CONCEPTS).to be_frozen
      expect(AiService::ARCHITECTURE_CONCEPTS).to include("service_boundaries", "failure_mode_design", "idempotency_at_scale")
    end

    it "is not mixed into any per-language generation vocabulary" do
      expect(AiService::RAILS_CONCEPTS & AiService::ARCHITECTURE_CONCEPTS).to be_empty
      expect(AiService::JS_CONCEPTS & AiService::ARCHITECTURE_CONCEPTS).to be_empty
    end
  end

  describe "SCENARIO_DOMAINS" do
    it "is a frozen list of scenario flavors, including a rare legacy-GraphQL entry" do
      expect(AiService::SCENARIO_DOMAINS).to be_frozen
      expect(AiService::SCENARIO_DOMAINS).to include(
        "background_job_processing", "api_versioning_and_deprecation",
        "activerecord_query_construction", "component_state_management",
        "legacy_graphql_maintenance"
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
  end

  describe "#build_exercise_prompt" do
    it "instructs that teaching notes hint without giving the answer" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("teaching_note")
      expect(prompt.downcase).to include("never the full answer")
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

    it "lists the architecture vocabulary for the architecture section when third: :architecture" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :architecture)
      expect(prompt).to include(AiService::ARCHITECTURE_CONCEPTS.join(", "))
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))   # still governs code_review/pattern
      expect(prompt.downcase).to include("architecture")
    end

    it "lists only the language vocabulary when third: :challenge" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :challenge)
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))
      expect(prompt).not_to include(AiService::ARCHITECTURE_CONCEPTS.join(", "))
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

    it "instructs a short architecture scenario with a hard constraint cap" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :architecture)
      expect(prompt).to include("~50 words maximum")
      expect(prompt).to include("exactly 2-3 concrete constraints")
      expect(prompt).to include("Fewer constraints, not fuzzier ones")
    end

    it "no longer enumerates team size, budget, and timeline as things to include" do
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :architecture)
      expect(prompt).not_to include("team size, scale, reliability needs, existing tech debt")
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
  end

  describe "retention check selection" do
    def mastery(concept:, bucket:, due_on:)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: due_on)
    end

    it "fills only the slots reinforcement did not claim" do
      mastery(concept: "memoization", bucket: "ruby_rails", due_on: Date.current - 2)
      allow(user).to receive(:concepts_needing_reinforcement)
        .and_return([ { concept: "a", tier: "standard" }, { concept: "b", tier: "standard" } ])

      checks = service.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 1)
      expect(checks.map(&:concept)).to eq(%w[memoization])
    end

    it "prioritizes a threshold-crossed short-interval concept over a merely-due long-interval one" do
      # "n_plus_one": interval 28, due 20 days ago — due, but not yet overdue by
      # its own interval (would need 28 days past due to cross the threshold).
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: 28,
                                     next_retention_check_on: Date.current - 20)
      # "memoization": interval 7, due 10 days ago — has crossed its own
      # threshold (10 > 7). Sorting by raw due-date alone would rank n_plus_one
      # first (20 days ago < 10 days ago); sorting by overdue-ratio must not.
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 10)

      checks = service.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 1)
      expect(checks.map(&:concept)).to eq(%w[memoization])
    end

    it "offers nothing when reinforcement already claims three slots" do
      mastery(concept: "memoization", bucket: "ruby_rails", due_on: Date.current - 2)
      expect(service.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 0)).to eq([])
    end

    it "offers architecture-bucket concepts only on architecture days" do
      mastery(concept: "service_boundaries", bucket: "architecture", due_on: Date.current - 2)

      on_challenge = service.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 3)
      on_arch      = service.send(:retention_checks_for, user, "ruby_rails", third: :architecture, slots: 3)

      expect(on_challenge.map(&:concept)).to eq([])
      expect(on_arch.map(&:concept)).to eq(%w[service_boundaries])
    end

    it "never offers a concept from the other language's bucket" do
      mastery(concept: "closures", bucket: "javascript", due_on: Date.current - 2)
      checks = service.send(:retention_checks_for, user, "ruby_rails", third: :challenge, slots: 3)
      expect(checks.map(&:concept)).to eq([])
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

    it "annotates an architecture-bucket concept as architecture-section-only" do
      cm = user.concept_masteries.create!(concept: "service_boundaries", language: "architecture", tier: :standard,
                                          mastered_at: 1.month.ago, retention_interval_days: 7,
                                          next_retention_check_on: Date.current - 2)
      prompt = service.send(:build_exercise_prompt, user, "ruby_rails", third: :architecture,
                            reinforcement: [], due_checks: [ cm ])

      expect(prompt).to include("Retention checks due today: service_boundaries (architecture section)")
    end
  end

  describe "#normalize_concepts" do
    it "keeps on-list concepts and maps off-list ones to 'other'" do
      set = {
        "code_review" => { "concept" => "n_plus_one" },
        "pattern" => { "concept" => "N+1 Queries!!" },
        "challenge" => { "question" => "no concept key" }
      }
      out = service.send(:normalize_concepts, set)
      expect(out["code_review"]["concept"]).to eq("n_plus_one")
      expect(out["pattern"]["concept"]).to eq("other")
      expect(out["challenge"]).not_to have_key("concept")
    end

    it "validates against the JS vocabulary when language is javascript" do
      set = {
        "code_review" => { "concept" => "closures" },
        "pattern" => { "concept" => "n_plus_one" }
      }
      out = service.send(:normalize_concepts, set, "javascript")
      expect(out["code_review"]["concept"]).to eq("closures")
      expect(out["pattern"]["concept"]).to eq("other")
    end

    it "records a SuggestedConcept for an off-list concept" do
      set = { "pattern" => { "concept" => "N+1 Queries!!" } }

      expect {
        service.send(:normalize_concepts, set)
      }.to change(SuggestedConcept, :count).by(1)

      concept = SuggestedConcept.last
      expect(concept.language).to eq("ruby_rails")
      expect(concept.display_name).to eq("N+1 Queries!!")
    end

    it "does not record a SuggestedConcept for an on-list concept" do
      set = { "code_review" => { "concept" => "n_plus_one" } }

      expect {
        service.send(:normalize_concepts, set)
      }.not_to change(SuggestedConcept, :count)
    end

    it "does not record a SuggestedConcept for a section with no concept key" do
      set = { "challenge" => { "question" => "no concept key" } }

      expect {
        service.send(:normalize_concepts, set)
      }.not_to change(SuggestedConcept, :count)
    end

    it "swallows a recording failure and still returns the normalized problem set" do
      allow(SuggestedConcept).to receive(:record!).and_raise(StandardError, "db down")
      set = { "pattern" => { "concept" => "N+1 Queries!!" } }

      result = nil
      expect(Rails.logger).to receive(:warn).with(/SuggestedConcept recording failed.*db down/)
      expect { result = service.send(:normalize_concepts, set) }.not_to raise_error
      expect(result["pattern"]["concept"]).to eq("other")
    end

    it "validates the architecture section against ARCHITECTURE_CONCEPTS regardless of language" do
      set = {
        "code_review"  => { "concept" => "n_plus_one" },
        "architecture" => { "concept" => "service_boundaries" }
      }
      out = service.send(:normalize_concepts, set, "javascript")
      expect(out["architecture"]["concept"]).to eq("service_boundaries")   # in arch vocab, kept
      expect(out["code_review"]["concept"]).to eq("other")                 # not in JS vocab
    end

    it "maps an off-list architecture concept to 'other' and records it under the 'architecture' bucket" do
      set = { "architecture" => { "concept" => "Microservices Everywhere!!" } }

      expect {
        service.send(:normalize_concepts, set, "ruby_rails")
      }.to change(SuggestedConcept, :count).by(1)

      expect(set["architecture"]["concept"]).to eq("other")
      expect(SuggestedConcept.last.language).to eq("architecture")
    end

    it "does not treat a Rails concept as valid in the architecture section" do
      set = { "architecture" => { "concept" => "n_plus_one" } }
      out = service.send(:normalize_concepts, set, "ruby_rails")
      expect(out["architecture"]["concept"]).to eq("other")
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
    it "raises rather than returning a problem set that isn't a JSON object" do
      svc = double_class.new(canned_text: '["not", "a", "problem set"]')

      expect {
        svc.generate_exercise(user)
      }.to raise_error(AiService::InvalidResponseError, /Array instead of a JSON object/)
    end

    it "logs usage and normalizes concepts from the provider's response using the resolved language" do
      set = { "code_review" => { "concept" => "bogus" } }
      svc = double_class.new(canned_text: set.to_json, input_tokens: 5, output_tokens: 7)

      result = svc.generate_exercise(user)

      expect(result["code_review"]["concept"]).to eq("other")
      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(5)
      expect(usage.tokens_out).to eq(7)
      expect(usage.purpose).to eq("generate_exercise")
    end

    it "normalizes against the JS vocabulary when an explicit javascript language is passed" do
      set = { "code_review" => { "concept" => "closures" } }
      svc = double_class.new(canned_text: set.to_json)

      result = svc.generate_exercise(user, language: "javascript")

      expect(result["code_review"]["concept"]).to eq("closures")
    end

    it "defaults language to the user's language_for_today when not passed explicitly" do
      user.update!(language: "javascript")
      set = { "code_review" => { "concept" => "closures" } }
      svc = double_class.new(canned_text: set.to_json)

      result = svc.generate_exercise(user)

      expect(result["code_review"]["concept"]).to eq("closures")
    end

    it "threads the rolled third-section kind into the exercise prompt" do
      set = { "code_review" => { "concept" => "n_plus_one" } }
      svc = double_class.new(canned_text: set.to_json)
      allow(svc).to receive(:roll_third_section).and_return(:architecture)
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
      set = { "code_review" => { "concept" => "n_plus_one" } }
      svc = spy_class.new(canned_text: set.to_json)
      allow(svc).to receive(:roll_third_section).and_return(:challenge)

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
        svc = spy_class.new(canned_text: { "code_review" => { "concept" => "n_plus_one" } }.to_json)
        allow(svc).to receive(:roll_third_section).and_return(third)

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
      set = { "code_review" => { "concept" => "memoization" } }
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      expect(Rails.logger).to receive(:info).with(/\[retention\].*offered=memoization.*honored=memoization/)
      svc.generate_exercise(user, language: "ruby_rails")
    end

    it "logs an empty honored list when the model ignored the due concept" do
      due_mastery
      set = { "code_review" => { "concept" => "n_plus_one" } }
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      expect(Rails.logger).to receive(:info).with(/\[retention\].*offered=memoization.*honored=-.*tagged=n_plus_one/)
      svc.generate_exercise(user, language: "ruby_rails")
    end

    it "logs nothing when no check is due" do
      set = { "code_review" => { "concept" => "n_plus_one" } }
      svc = double_class.new(canned_text: set.to_json)
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])

      expect(Rails.logger).not_to receive(:info).with(/\[retention\]/)
      svc.generate_exercise(user, language: "ruby_rails")
    end
  end

  describe "#review_response" do
    def sample_exercise(language)
      DailyExercise.new(
        language: language,
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s" },
          "pattern" => { "title" => "t", "question" => "q" },
          "challenge" => { "question" => "q" }
        }
      )
    end

    it "asks for correct/missed/better_questions as arrays and next_step as a string" do
      ex = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "cr?", "snippet" => "code" },
        "pattern"     => { "title" => "P", "question" => "pat?" },
        "challenge"   => { "question" => "Implement uniq_by" }
      })
      resp = DailyResponse.new(answers: { "code_review" => "It's an N+1" })
      prompt = service.send(:build_review_prompt, ex, resp)

      expect(prompt).to include('"correct": array of strings')
      expect(prompt).to include('"missed": array of strings')
      expect(prompt).to include('"better_questions": array of strings')
      expect(prompt).to include('"next_step": string')
      expect(prompt).to match(/separate ideas belong in separate entries/i)
    end

    it "names pattern as code-bearing and asks for a refactored structure" do
      ex = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "cr?", "snippet" => "code" },
        "pattern"     => { "title" => "P", "question" => "pat?" },
        "challenge"   => { "question" => "Implement uniq_by" }
      })
      resp = DailyResponse.new(answers: { "pattern" => "Extract a service object" })
      prompt = service.send(:build_review_prompt, ex, resp)

      expect(prompt).to include("code_review, pattern, and challenge")
      expect(prompt).to match(/refactored structure/i)
    end

    context "architecture third section" do
      def arch_exercise
        DailyExercise.new(
          language: "ruby_rails",
          problem_set: {
            "code_review" => { "question" => "cr?", "snippet" => "code" },
            "pattern"     => { "title" => "P", "question" => "pat?" },
            "architecture" => { "title" => "A", "question" => "Pick a datastore approach?",
                                "scenario" => "10x traffic spike expected" }
          }
        )
      end

      it "evaluates tradeoff reasoning, constraints, and alternatives — not correctness" do
        resp = DailyResponse.new(answers: { "architecture" => "I'd shard because..." })
        prompt = service.send(:build_review_prompt, arch_exercise, resp)
        expect(prompt).to include("Pick a datastore approach?")
        expect(prompt).to include("10x traffic spike expected")
        expect(prompt.downcase).to include("tradeoff")
        expect(prompt.downcase).to include("alternatives")
        expect(prompt).to include('"architecture"')   # asks for the architecture key back
        expect(prompt).not_to include("Coding Challenge:")
        expect(prompt).to include('For this section "improved_code" must be an empty string.')
      end
    end

    it "keeps the existing challenge criteria when the third section is a challenge" do
      ex = DailyExercise.new(language: "ruby_rails", problem_set: {
        "code_review" => { "question" => "cr?", "snippet" => "code" },
        "pattern"     => { "title" => "P", "question" => "pat?" },
        "challenge"   => { "question" => "Implement uniq_by" }
      })
      resp = DailyResponse.new(answers: { "challenge" => "def uniq_by..." })
      prompt = service.send(:build_review_prompt, ex, resp)
      expect(prompt).to include("Coding Challenge: Implement uniq_by")
      expect(prompt).to include('"challenge"')
    end

    it "names Rails in the system prompt for a ruby_rails exercise" do
      spy_class = Class.new(double_class) do
        attr_reader :last_system

        def call(system:, prompt:)
          @last_system = system
          super
        end
      end
      svc = spy_class.new

      svc.review_response(user, sample_exercise("ruby_rails"), instance_double(DailyResponse, answers: {}))

      expect(svc.last_system).to include("senior Rails engineer")
    end

    it "names JavaScript/React in the system prompt for a javascript exercise" do
      spy_class = Class.new(double_class) do
        attr_reader :last_system

        def call(system:, prompt:)
          @last_system = system
          super
        end
      end
      svc = spy_class.new

      svc.review_response(user, sample_exercise("javascript"), instance_double(DailyResponse, answers: {}))

      expect(svc.last_system).to include("senior JavaScript/React engineer")
    end

    it "returns the AI service's stubbed feedback for the submitted answers to each JSON question" do
      exercise = sample_exercise("ruby_rails")
      daily_response = instance_double(DailyResponse, answers: {
        "code_review" => "It's an N+1 query — fix with includes.",
        "pattern"     => "Extract a scope object.",
        "challenge"   => "def foo; end"
      })

      feedback = {
        "code_review" => { "rating" => "solid", "correct" => "Spotted the N+1", "missed" => "", "better_questions" => "", "next_step" => "", "improved_code" => "" },
        "pattern"     => { "rating" => "developing", "correct" => "", "missed" => "Missed the edge case", "better_questions" => "", "next_step" => "", "improved_code" => "" },
        "challenge"   => { "rating" => "strong", "correct" => "Works as specified", "missed" => "", "better_questions" => "", "next_step" => "", "improved_code" => "" }
      }

      spy_class = Class.new(double_class) do
        attr_reader :last_prompt

        def call(system:, prompt:)
          @last_prompt = prompt
          super
        end
      end
      svc = spy_class.new(canned_text: feedback.to_json)

      result = svc.review_response(user, exercise, daily_response)

      expect(result).to eq(feedback)
      expect(svc.last_prompt).to include(exercise.code_review["question"])
      expect(svc.last_prompt).to include("It's an N+1 query — fix with includes.")
      expect(svc.last_prompt).to include(exercise.pattern["question"])
      expect(svc.last_prompt).to include("Extract a scope object.")
      expect(svc.last_prompt).to include(exercise.challenge["question"])
      expect(svc.last_prompt).to include("def foo; end")
    end

    # A review that isn't a JSON object would still be truthy once persisted to
    # ai_review, which flips DailyResponse#reviewed? and permanently retires the
    # "Get review" button — leaving the user with an empty review and no retry.
    it "raises rather than returning a review that isn't a JSON object" do
      svc = double_class.new(canned_text: '["not", "an", "object"]')

      expect {
        svc.review_response(user, sample_exercise("ruby_rails"), instance_double(DailyResponse, answers: {}))
      }.to raise_error(AiService::InvalidResponseError, /instead of a JSON object/)
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
        def call(system:, prompt:)
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
        def call(system:, prompt:)
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
end
