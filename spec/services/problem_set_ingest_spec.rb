require "rails_helper"

# No test outside this file may touch a step; callers and their specs assert through .call.
RSpec.describe ProblemSetIngest do
  # The steps are ordered and none undoes another, so one field after a full run tests that step.
  def step(problem_set, language: "ruby_rails")
    described_class.call(problem_set, language: language, expected_keys: problem_set.keys).problem_set
  rescue AiService::InvalidResponseError
    raise
  end

  def ingest(problem_set, language: "ruby_rails")
    described_class.call(problem_set, language: language, expected_keys: problem_set.keys)
  end

  describe "grounding a code_review in real source" do
    let(:excerpt) { RealSource::APPLICATION_CODE.first }

    def grounded(problem_set, source:)
      described_class.call(problem_set, language: "ruby_rails", expected_keys: problem_set.keys,
                           code_review_source: source).problem_set
    end

    it "stamps the server's scenario over whatever the provider wrote" do
      set = grounded({ "code_review" => { "concept" => "memoization", "scenario" => "inventory restocking service" } },
                     source: excerpt)

      expect(set["code_review"]["scenario"]).to eq(excerpt.scenario)
    end

    it "leaves the trace the next pick reads" do
      set = grounded({ "code_review" => { "concept" => "memoization" } }, source: excerpt)

      expect(set["code_review"]["source"]).to eq(excerpt.id)
    end

    it "leaves the provider's scenario alone on a toy day" do
      set = grounded({ "code_review" => { "concept" => "memoization", "scenario" => "inventory restocking service" } },
                     source: nil)

      expect(set["code_review"]["scenario"]).to eq("inventory restocking service")
      expect(set["code_review"]).not_to have_key("source")
    end

    it "strips a provider-supplied source on a toy day, so a set that never showed an excerpt cannot mark it seen" do
      set = grounded({ "code_review" => { "concept" => "memoization", "source" => excerpt.id } }, source: nil)

      expect(set["code_review"]).not_to have_key("source")
    end

    describe "the current schema" do
      # A double, since a real Migration reads db/schema.rb and this file stays disk-free.
      let(:migration) do
        instance_double(RealSource::Migration, scenario: "Modelled on Code Gym's own migration",
                                               id: "db/migrate/1_create_things.rb",
                                               current_schema: %(create_table "things" do |t|\nend\n))
      end

      it "stamps the server's own on a grounded migration day" do
        set = grounded({ "code_review" => { "concept" => "wrong_cardinality", "current_schema" => "invented" } },
                       source: migration)

        expect(set["code_review"]["current_schema"]).to eq(migration.current_schema)
      end

      it "strips a provider-supplied one on a toy day" do
        set = grounded({ "code_review" => { "concept" => "memoization", "current_schema" => "invented" } }, source: nil)

        expect(set["code_review"]).not_to have_key("current_schema")
      end

      it "strips a provider-supplied one on a method day, which has no table" do
        set = grounded({ "code_review" => { "concept" => "memoization", "current_schema" => "invented" } },
                       source: excerpt)

        expect(set["code_review"]).not_to have_key("current_schema")
      end

      it "strips a provider-supplied one from every other section, leaving the stamp alone" do
        set = grounded({ "code_review" => { "concept" => "wrong_cardinality" },
                         "pattern" => { "concept" => "memoization", "current_schema" => "invented" } },
                       source: migration)

        expect(set["pattern"]).not_to have_key("current_schema")
        expect(set["code_review"]["current_schema"]).to eq(migration.current_schema)
      end
    end
  end

  describe ".call" do
    it "returns the cleaned problem set and the concepts it could not place" do
      result = ingest({ "code_review" => { "concept" => "not_a_real_concept" } })

      expect(result.problem_set["code_review"]["concept"]).to eq("other")
      expect(result.suggested_concepts.map(&:name)).to eq([ "not_a_real_concept" ])
      expect(result.suggested_concepts.map(&:bucket)).to eq([ "ruby_rails" ])
    end

    it "reports no suggestions when every concept is on its vocabulary" do
      result = ingest({ "code_review" => { "concept" => "n_plus_one" } })

      expect(result.suggested_concepts).to be_empty
    end

    it "reports nothing at all when the set is rejected" do
      set = { "ambiguity_hunt" => { "concept" => "invented_concept", "planted_ambiguities" => [] } }

      expect { ingest(set) }.to raise_error(AiService::InvalidResponseError, /No usable section left/)
    end

    describe "a section its kind refuses" do
      it "leaves only that section out and reports it with its concept and the check's reason" do
        hunt = { "code_review" => { "concept" => "n_plus_one" },
                 "ambiguity_hunt" => { "concept" => "missing_success_criteria", "planted_ambiguities" => [] } }
        result = ingest(hunt)

        expect(result.problem_set.keys).to eq([ "code_review" ])
        expect(result.unusable_sections).to eq([
          described_class::Unusable.new(key: "ambiguity_hunt", concept: "missing_success_criteria",
                                        reason: "Ambiguity hunt returned no usable planted_ambiguities to grade coverage against")
        ])
      end

      it "checks the lower-precedence shape that takes a refused section's slot" do
        pseudo = { "code_review" => { "concept" => "n_plus_one" },
                   "ambiguity_hunt" => { "concept" => "missing_success_criteria", "planted_ambiguities" => [] },
                   "pseudocode_to_code" => { "concept" => "x", "problem_statement" => " " } }
        result = ingest(pseudo)

        expect(result.problem_set.keys).to eq([ "code_review" ])
        expect(result.unusable_sections.map(&:key)).to eq(%w[ambiguity_hunt pseudocode_to_code])
      end

      it "keeps a requested, usable lower-precedence shape when an unrequested one above it is refused" do
        pseudo = { "code_review" => { "concept" => "n_plus_one" },
                   "ambiguity_hunt" => { "concept" => "missing_success_criteria", "planted_ambiguities" => [] },
                   "pseudocode_to_code" => { "concept" => "x", "problem_statement" => "Write the function" } }
        result = described_class.call(pseudo, language: "ruby_rails", expected_keys: %w[code_review pseudocode_to_code])

        expect(result.problem_set.keys).to contain_exactly("code_review", "pseudocode_to_code")
        expect(result.unusable_sections.map(&:key)).to eq([ "ambiguity_hunt" ])
      end

      it "reports no concept when the refused section's tag is off its vocabulary" do
        result = ingest({ "code_review" => { "concept" => "n_plus_one" },
                          "pseudocode_to_code" => { "concept" => "invented", "problem_statement" => "" } })

        expect(result.unusable_sections.sole.concept).to be_nil
      end

      it "still refuses a set missing a requested key entirely" do
        expect { described_class.call({ "code_review" => {} }, language: "ruby_rails", expected_keys: %w[code_review pattern]) }
          .to raise_error(AiService::InvalidResponseError, /omitted/)
      end

      it "reports nothing for a set with nothing to refuse" do
        expect(ingest({ "code_review" => { "concept" => "n_plus_one" } }).unusable_sections).to eq([])
      end
    end

    it "writes no SuggestedConcept rows of its own" do
      expect { ingest({ "code_review" => { "concept" => "invented_concept" } }) }
        .not_to change(SuggestedConcept, :count)
    end
  end

  describe ".prune_to_expected_keys" do
    it "returns a deep-duped set containing only the expected keys" do
      drafted = {
        "code_review" => { "concept" => "n_plus_one" },
        "parsons_problem" => {
          "concept" => "memoization",
          "blocks" => [ "one", "two", "three", "four" ],
          "display_order" => [ 1, 3, 2, 0 ]
        },
        "architecture" => { "concept" => "sync_vs_async" }
      }

      pruned = described_class.prune_to_expected_keys(drafted, expected_keys: %w[code_review parsons_problem])
      pruned["parsons_problem"]["display_order"] << 4

      expect(pruned.keys).to contain_exactly("code_review", "parsons_problem")
      expect(drafted.keys).to contain_exactly("code_review", "parsons_problem", "architecture")
      expect(drafted.dig("parsons_problem", "display_order")).to eq([ 1, 3, 2, 0 ])
    end
  end

  describe ".selectable_vocabulary_for" do
    it "hands the kind's own hook what the excluded groups left, with the rung" do
      after_exclusions = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")
      allow(ExerciseSection::ParsonsProblem).to receive(:narrow_vocabulary).and_return(%w[n_plus_one])

      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails", rung: "senior")

      expect(vocabulary).to eq(%w[n_plus_one])
      expect(ExerciseSection::ParsonsProblem).to have_received(:narrow_vocabulary)
        .with(after_exclusions, rung: "senior")
    end

    it "passes no rung when the caller names none" do
      allow(ExerciseSection::Pattern).to receive(:narrow_vocabulary).and_call_original

      described_class.selectable_vocabulary_for("pattern", "ruby_rails")

      expect(ExerciseSection::Pattern).to have_received(:narrow_vocabulary).with(AiService::RAILS_CONCEPTS, rung: nil)
    end

    it "withholds every data-modeling concept from parsons_problem" do
      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*AiService::DATA_MODELING_CONCEPTS)
      expect(vocabulary).to include("n_plus_one")
    end

    it "withholds them in both languages" do
      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_vocabulary_for("parsons_problem", language))
          .not_to include(*AiService::DATA_MODELING_CONCEPTS)
      end
    end

    it "changes nothing about parsons beyond the exclusion" do
      excluded = AiService::DATA_MODELING_CONCEPTS + AiService::DOMAIN_MODELING_CONCEPTS +
                 AiService::META_SKILL_CONCEPTS +
                 AiService::CODE_SMELL_CONCEPTS + AiService::OO_DESIGN_CONCEPTS +
                 AiService::MODULE_DESIGN_CONCEPTS + AiService::SILENT_CORRECTNESS_CONCEPTS

      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_vocabulary_for("parsons_problem", language))
          .to eq(described_class.selectable_vocabulary_for("challenge", language) - excluded)
      end
    end

    it "leaves every other kind's selectable vocabulary alone" do
      %w[pattern challenge security_review architecture plan_review ambiguity_hunt].each do |key|
        expect(described_class.selectable_vocabulary_for(key, "ruby_rails"))
          .to eq(described_class.vocabulary_for(key, "ruby_rails")), "#{key} was narrowed unexpectedly"
      end
    end

    it "still narrows code_review by its content mode" do
      expect(described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review))
        .to eq(AiService::DATA_MODELING_CONCEPTS)
    end

    it "withholds every meta-skill concept from parsons_problem in both languages" do
      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_vocabulary_for("parsons_problem", language))
          .not_to include(*AiService::META_SKILL_CONCEPTS)
      end
    end

    it "offers the meta-skill concepts to code_review, pattern, and challenge" do
      %w[ruby_rails javascript].each do |language|
        %w[pattern challenge].each do |key|
          expect(described_class.selectable_vocabulary_for(key, language))
            .to include(*AiService::META_SKILL_CONCEPTS), "#{key}/#{language} was missing the group"
        end

        %i[application_code test_file].each do |mode|
          expect(described_class.selectable_vocabulary_for("code_review", language, mode: mode))
            .to include(*AiService::META_SKILL_CONCEPTS)
        end
      end
    end

    it "withholds them from the kinds whose own vocabulary is disjoint" do
      %w[security_review architecture plan_review ambiguity_hunt].each do |key|
        expect(described_class.selectable_vocabulary_for(key, "ruby_rails"))
          .not_to include(*AiService::META_SKILL_CONCEPTS), "#{key} could be offered a meta-skill concept"
      end
    end

    it "withholds code smells from parsons_problem, whose format has nothing to recognize" do
      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*AiService::CODE_SMELL_CONCEPTS)
    end

    it "offers code smells to code_review outside schema-review mode" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :application_code)

      expect(vocabulary).to include(*AiService::CODE_SMELL_CONCEPTS)
    end

    it "withholds code smells from a schema-review code_review" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*AiService::CODE_SMELL_CONCEPTS)
    end

    it "withholds OO design principles from parsons_problem, whose grade is an ordering" do
      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*AiService::OO_DESIGN_CONCEPTS)
    end

    it "withholds module-design concepts from parsons_problem, whose grade is an ordering" do
      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*AiService::MODULE_DESIGN_CONCEPTS)
    end

    it "offers module-design concepts to code_review outside schema-review mode" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "javascript", mode: :application_code)

      expect(vocabulary).to include(*AiService::MODULE_DESIGN_CONCEPTS)
    end

    it "offers OO design principles to code_review outside schema-review mode" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "javascript", mode: :application_code)

      expect(vocabulary).to include(*AiService::OO_DESIGN_CONCEPTS)
    end

    # #oo_design_violation_guidance's test-file idiom assumes this; revisit it if selection narrows.
    it "offers every OO design principle to a test-file code_review" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :test_file)

      expect(vocabulary).to include(*AiService::OO_DESIGN_CONCEPTS)
    end

    it "withholds OO design principles from a schema-review code_review" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*AiService::OO_DESIGN_CONCEPTS)
    end

    it "withholds silent-correctness concepts from parsons_problem, whose grade is an ordering" do
      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*AiService::SILENT_CORRECTNESS_CONCEPTS)
    end

    it "offers silent-correctness concepts to code_review, pattern, and challenge in both languages" do
      %w[ruby_rails javascript].each do |language|
        %w[pattern challenge].each do |key|
          expect(described_class.selectable_vocabulary_for(key, language))
            .to include(*AiService::SILENT_CORRECTNESS_CONCEPTS), "#{key}/#{language} was missing the group"
        end

        %i[application_code test_file].each do |mode|
          expect(described_class.selectable_vocabulary_for("code_review", language, mode: mode))
            .to include(*AiService::SILENT_CORRECTNESS_CONCEPTS), "code_review/#{mode}/#{language} was missing the group"
        end
      end
    end

    it "withholds silent-correctness concepts from a schema-review code_review" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*AiService::SILENT_CORRECTNESS_CONCEPTS)
    end

    it "withholds them from the kinds whose own vocabulary is disjoint" do
      %w[security_review architecture plan_review ambiguity_hunt pseudocode_to_code].each do |key|
        expect(described_class.selectable_vocabulary_for(key, "ruby_rails"))
          .not_to include(*AiService::SILENT_CORRECTNESS_CONCEPTS), "#{key} could be offered a silent-correctness concept"
      end
    end

    it "withholds domain-modeling concepts from parsons_problem, whose positional grade cannot measure naming or write paths" do
      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_vocabulary_for("parsons_problem", language))
          .not_to include(*AiService::DOMAIN_MODELING_CONCEPTS)
      end
    end

    it "offers domain-modeling concepts to code_review, pattern, and challenge in both languages" do
      %w[ruby_rails javascript].each do |language|
        %w[pattern challenge].each do |key|
          expect(described_class.selectable_vocabulary_for(key, language))
            .to include(*AiService::DOMAIN_MODELING_CONCEPTS), "#{key}/#{language} was missing the group"
        end

        %i[application_code test_file].each do |mode|
          expect(described_class.selectable_vocabulary_for("code_review", language, mode: mode))
            .to include(*AiService::DOMAIN_MODELING_CONCEPTS), "code_review/#{mode}/#{language} was missing the group"
        end
      end
    end

    it "withholds domain-modeling concepts from a schema-review code_review" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*AiService::DOMAIN_MODELING_CONCEPTS)
    end

    it "withholds domain-modeling concepts from the kinds whose own vocabulary is disjoint" do
      %w[security_review architecture plan_review ambiguity_hunt pseudocode_to_code].each do |key|
        expect(described_class.selectable_vocabulary_for(key, "ruby_rails"))
          .not_to include(*AiService::DOMAIN_MODELING_CONCEPTS), "#{key} could be offered a domain-modeling concept"
      end
    end
  end

  describe ".vocabulary_for" do
    it "resolves each kind's vocabulary through its vocabulary_key" do
      expect(described_class.vocabulary_for("code_review", "ruby_rails")).to eq(AiService::RAILS_CONCEPTS)
      expect(described_class.vocabulary_for("code_review", "javascript")).to eq(AiService::JS_CONCEPTS)
      expect(described_class.vocabulary_for("architecture", "ruby_rails")).to eq(AiService::ARCHITECTURE_CONCEPTS)
      expect(described_class.vocabulary_for("security_review", "ruby_rails")).to eq(AiService::RAILS_SECURITY_CONCEPTS)
      expect(described_class.vocabulary_for("plan_review", "ruby_rails")).to eq(AiService::PLAN_REVIEW_CONCEPTS)
      expect(described_class.vocabulary_for("ambiguity_hunt", "ruby_rails")).to eq(AiService::AMBIGUITY_HUNT_CONCEPTS)
    end

    # Generation declines to ask for this, but an arriving tag is real; rewriting it would destroy history.
    it "still accepts a data-modeling concept tagged on parsons_problem" do
      expect(described_class.vocabulary_for("parsons_problem", "ruby_rails")).to include("missing_index")

      result = described_class.call({ "parsons_problem" => { "concept" => "missing_index" } }, language: "ruby_rails",
                                     expected_keys: %w[parsons_problem])

      expect(result.problem_set["parsons_problem"]["concept"]).to eq("missing_index")
      expect(result.suggested_concepts).to be_empty
    end

    it "falls back to the language vocabulary for a section key a provider invented" do
      expect(described_class.vocabulary_for("made_up_section", "ruby_rails")).to eq(AiService::RAILS_CONCEPTS)
    end

    it "returns the full language vocabulary for code_review with no mode, since ingest cannot tell which mode produced a set" do
      expect(described_class.vocabulary_for("code_review", "ruby_rails"))
        .to eq(AiService::RAILS_CONCEPTS)
    end

    it "narrows code_review to the data-modeling concepts on a schema-review day" do
      expect(described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review))
        .to eq(AiService::DATA_MODELING_CONCEPTS)
    end

    it "excludes the data-modeling concepts on the other two modes" do
      %i[application_code test_file].each do |mode|
        vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: mode)
        expect(vocabulary).not_to include(*AiService::DATA_MODELING_CONCEPTS)
        expect(vocabulary).to include("n_plus_one")
      end
    end

    it "leaves pattern unnarrowed on every mode" do
      %i[application_code test_file schema_review].each do |mode|
        expect(described_class.selectable_vocabulary_for("pattern", "ruby_rails", mode: mode))
          .to eq(AiService::RAILS_CONCEPTS)
      end
    end
  end

  describe "parsons block scrambling" do
    it "persists a display order that is a permutation of the blocks" do
      set = step({ "parsons_problem" => { "blocks" => %w[a b c d e] } })

      expect(set["parsons_problem"]["display_order"].sort).to eq([ 0, 1, 2, 3, 4 ])
    end

    it "never ships the already-solved arrangement" do
      20.times do
        set = step({ "parsons_problem" => { "blocks" => %w[a b c d e] } })
        expect(set["parsons_problem"]["display_order"]).not_to eq([ 0, 1, 2, 3, 4 ])
      end
    end

    it "leaves a single-block section alone rather than looping forever" do
      set = step({ "parsons_problem" => { "blocks" => %w[only] } })

      expect(set["parsons_problem"]["display_order"]).to eq([ 0 ])
    end

    it "ignores a parsons section with no blocks array" do
      set = step({ "parsons_problem" => { "question" => "q" } })

      expect(set["parsons_problem"]).not_to have_key("display_order")
    end

    it "leaves a parsons alternate that loses the third slot unarranged" do
      set = step({ "architecture" => { "question" => "q" },
                  "parsons_problem" => { "blocks" => %w[a b c d e] } })

      expect(ExerciseSection.resolved_keys(set)).not_to include("parsons_problem")
      expect(set["parsons_problem"]).not_to have_key("display_order")
    end
  end

    describe "the answer key"  do
      def planted(*entries)
        { "ambiguity_hunt" => { "request" => "vague", "planted_ambiguities" => entries.flatten(1) } }
      end

      def exactly_enough
        Array.new(ExerciseSection::AmbiguityHunt::PLANTED_COUNT) { |i| "ambiguity #{i}" }
      end

      it "passes a list of exactly the planted count through" do
        set = planted(exactly_enough)
        result = step(set)
        expect(result["ambiguity_hunt"]["planted_ambiguities"]).to eq(exactly_enough)
      end

      it "strips whitespace off each entry" do
        set = planted(exactly_enough.map { |a| "  #{a}\n" })
        step(set)
        expect(set["ambiguity_hunt"]["planted_ambiguities"]).to eq(exactly_enough)
      end

      def refusal_of(hunt)
        ingest({ "code_review" => { "concept" => "n_plus_one" } }.merge(hunt)).unusable_sections.map(&:reason)
      end

      it "leaves the hunt out when the field is missing entirely" do
        expect(refusal_of({ "ambiguity_hunt" => { "request" => "vague" } })).to contain_exactly(/no usable planted_ambiguities/)
      end

      it "leaves the hunt out when the field is not an array" do
        expect(refusal_of({ "ambiguity_hunt" => { "planted_ambiguities" => "one; two; three; four" } }))
          .to contain_exactly(/no usable planted_ambiguities/)
      end

      it "leaves the hunt out when every entry is unusable" do
        expect(refusal_of(planted([ "   ", nil, 42, "" ]))).to contain_exactly(/no usable planted_ambiguities/)
      end

      it "keeps a gradable list that came back short of the asked-for count" do
        set = planted(exactly_enough.first(2) + [ "  ", nil ])
        step(set)
        expect(set["ambiguity_hunt"]["planted_ambiguities"]).to eq(exactly_enough.first(2))
      end

      it "keeps a list that came back over the asked-for count, up to the ingest bound" do
        set = planted(exactly_enough + [ "one more" ])
        step(set)
        expect(set["ambiguity_hunt"]["planted_ambiguities"]).to eq(exactly_enough + [ "one more" ])
      end

      it "truncates a runaway list at AmbiguityHunt::MAX_PLANTED" do
        set = planted(Array.new(40) { |i| "ambiguity #{i}" })
        step(set)
        expect(set["ambiguity_hunt"]["planted_ambiguities"].size).to eq(ExerciseSection::AmbiguityHunt::MAX_PLANTED)
      end

      it "does nothing for a problem set with no ambiguity_hunt section" do
        set = { "plan_review" => { "plan_excerpt" => "a plan" } }
        expect { step(set) }.not_to raise_error
      end

      it "ignores an unusable list on an ambiguity_hunt that lost the fourth slot to plan_review" do
        set = {
          "plan_review"    => { "plan_excerpt" => "a plan" },
          "ambiguity_hunt" => { "request" => "vague" }
        }

        expect { step(set) }.not_to raise_error
      end
    end

    describe "the pseudocode problem statement" do
      def pseudocode(statement)
        { "pseudocode_to_code" => { "title" => "P2C", "problem_statement" => statement } }
      end

      it "strips the statement" do
        expect(step(pseudocode("  merge ranges \n"))["pseudocode_to_code"]["problem_statement"]).to eq("merge ranges")
      end

      it "truncates a runaway statement at PseudocodeToCode::MAX_PROBLEM_STATEMENT_LENGTH" do
        statement = step(pseudocode("x" * 5_000))["pseudocode_to_code"]["problem_statement"]

        expect(statement.length).to eq(ExerciseSection::PseudocodeToCode::MAX_PROBLEM_STATEMENT_LENGTH)
      end

      it "leaves the section out when the statement is blank or not a string" do
        [ nil, "   ", 42, [ "merge ranges" ] ].each do |statement|
          result = ingest({ "code_review" => { "concept" => "n_plus_one" } }.merge(pseudocode(statement)))

          expect(result.problem_set).not_to have_key("pseudocode_to_code")
          expect(result.unusable_sections.map(&:reason)).to contain_exactly(/no usable problem_statement/)
        end
      end

      it "ignores an unusable statement on a section that lost the fourth slot" do
        set = pseudocode(nil).merge("ambiguity_hunt" => { "planted_ambiguities" => [ "who can see it?" ] })

        expect { step(set) }.not_to raise_error
      end
    end

    describe "each kind's own boundary check" do
      it "runs only for the sections the set resolves to" do
        allow(ExerciseSection::PlanReview).to receive(:reject_unusable!)
        allow(ExerciseSection::AmbiguityHunt).to receive(:reject_unusable!)
        allow(ExerciseSection::Architecture).to receive(:reject_unusable!)
        allow(ExerciseSection::Challenge).to receive(:reject_unusable!)
        set = {
          "code_review"    => { "concept" => "n_plus_one" },
          "architecture"   => { "question" => "which?" },
          "challenge"      => { "question" => "unrendered alternate" },
          "plan_review"    => { "plan_excerpt" => "a plan" },
          "ambiguity_hunt" => { "request" => "vague" }
        }

        step(set)

        expect(ExerciseSection::Architecture).to have_received(:reject_unusable!).with(set["architecture"])
        expect(ExerciseSection::PlanReview).to have_received(:reject_unusable!).with(set["plan_review"])
        expect(ExerciseSection::Challenge).not_to have_received(:reject_unusable!)
        expect(ExerciseSection::AmbiguityHunt).not_to have_received(:reject_unusable!)
      end
    end

    describe "concepts" do
      it "keeps on-list concepts and maps off-list ones to 'other'" do
        set = {
          "code_review" => { "concept" => "n_plus_one" },
          "pattern" => { "concept" => "N+1 Queries!!" },
          "challenge" => { "question" => "no concept key" }
        }
        out = step(set)
        expect(out["code_review"]["concept"]).to eq("n_plus_one")
        expect(out["pattern"]["concept"]).to eq("other")
        expect(out["challenge"]).not_to have_key("concept")
      end

      it "validates against the JS vocabulary when language is javascript" do
        set = {
          "code_review" => { "concept" => "closures" },
          "pattern" => { "concept" => "n_plus_one" }
        }
        out = step(set, language: "javascript")
        expect(out["code_review"]["concept"]).to eq("closures")
        expect(out["pattern"]["concept"]).to eq("other")
      end

      it "reports an off-list concept as a suggestion in the day's bucket" do
        result = ingest({ "pattern" => { "concept" => "N+1 Queries!!" } })

        expect(result.suggested_concepts.size).to eq(1)
        expect(result.suggested_concepts.first.bucket).to eq("ruby_rails")
        expect(result.suggested_concepts.first.name).to eq("N+1 Queries!!")
      end

      it "reports no suggestion for an on-list concept" do
        expect(ingest({ "code_review" => { "concept" => "n_plus_one" } }).suggested_concepts).to be_empty
      end

      it "reports no suggestion for a section with no concept key" do
        expect(ingest({ "challenge" => { "question" => "no concept key" } }).suggested_concepts).to be_empty
      end

      it "validates the architecture section against ARCHITECTURE_CONCEPTS regardless of language" do
        set = {
          "code_review"  => { "concept" => "n_plus_one" },
          "architecture" => { "concept" => "service_boundaries" }
        }
        out = step(set, language: "javascript")
        expect(out["architecture"]["concept"]).to eq("service_boundaries")
        expect(out["code_review"]["concept"]).to eq("other")
      end

      it "maps an off-list architecture concept to 'other' and reports it under the 'architecture' bucket" do
        set = { "architecture" => { "concept" => "Microservices Everywhere!!" } }

        result = ingest(set, language: "ruby_rails")

        expect(result.problem_set["architecture"]["concept"]).to eq("other")
        expect(result.suggested_concepts.map(&:bucket)).to eq([ "architecture" ])
      end

      it "does not treat a Rails concept as valid in the architecture section" do
        set = { "architecture" => { "concept" => "n_plus_one" } }
        out = step(set, language: "ruby_rails")
        expect(out["architecture"]["concept"]).to eq("other")
      end

      it "validates the security_review section against that language's security_concepts, not the full vocabulary" do
        set = {
          "code_review"     => { "concept" => "memoization" },
          "security_review" => { "concept" => "sql_injection_prevention" }
        }
        out = step(set, language: "ruby_rails")
        expect(out["code_review"]["concept"]).to eq("memoization")
        expect(out["security_review"]["concept"]).to eq("sql_injection_prevention")
      end

      it "maps an on-language-vocabulary but off-security-list concept in security_review to 'other'" do
        set = { "security_review" => { "concept" => "memoization" } }
        result = ingest(set, language: "ruby_rails")

        expect(result.problem_set["security_review"]["concept"]).to eq("other")
        expect(result.suggested_concepts.map(&:bucket)).to eq([ "ruby_rails" ])
      end
    end

    describe "concepts in the fourth-slot vocabularies" do
      it "keeps a valid plan_review concept and buckets suggestions under plan_review" do
        set = { "plan_review" => { "concept" => "scope_creep" } }
        result = step(set, language: "ruby_rails")
        expect(result["plan_review"]["concept"]).to eq("scope_creep")
      end

      it "normalizes an off-vocabulary plan_review concept to other" do
        set = { "plan_review" => { "concept" => "n_plus_one" } }
        result = step(set, language: "ruby_rails")
        expect(result["plan_review"]["concept"]).to eq("other")
      end

      it "keeps a valid ambiguity_hunt concept regardless of the day's language" do
        set = { "ambiguity_hunt" => { "concept" => "missing_success_criteria",
                                      "planted_ambiguities" => [ "a gap" ] } }
        result = step(set, language: "javascript")
        expect(result["ambiguity_hunt"]["concept"]).to eq("missing_success_criteria")
      end
    end

    describe "answer scaffolds" do
      it "keeps a usable scaffold on a scaffolded section" do
        set = { "pattern" => { "answer_scaffold" => [ "  Your approach:  ", "What breaks:" ] } }

        expect(step(set)["pattern"]["answer_scaffold"])
          .to eq([ "Your approach:", "What breaks:" ])
      end

      it "bounds a scaffold the model let run long or wide" do
        set = { "architecture" => { "answer_scaffold" => (1..9).map { |i| "L#{i}: " + "x" * 200 } } }

        labels = step(set)["architecture"]["answer_scaffold"]
        expect(labels.size).to eq(ExerciseSection::MAX_SCAFFOLD_LABELS)
        expect(labels.map(&:length)).to all(be <= ExerciseSection::MAX_SCAFFOLD_LABEL_LENGTH)
      end

      it "drops an unusable scaffold instead of persisting it" do
        [ "not an array", [], [ "", nil ], [ 42, true ], 42 ].each do |bad|
          set = { "pattern" => { "question" => "q", "answer_scaffold" => bad } }
          expect(step(set)["pattern"]).not_to have_key("answer_scaffold")
        end
      end

      it "strips a scaffold the model volunteered for an unscaffolded section" do
        set = { "code_review" => { "answer_scaffold" => [ "Nope:" ] } }

        expect(step(set)["code_review"]).not_to have_key("answer_scaffold")
      end

      it "leaves a section that carries no scaffold alone" do
        set = { "pattern" => { "question" => "q" } }

        expect(step(set)).to eq("pattern" => { "question" => "q" })
      end
    end

    describe "diagrams" do
      it "keeps a usable diagram on a diagrammable section" do
        set = { "code_review" => { "diagram" => "  flowchart TD\n  A[Job] --> B[(DB)]  " } }

        expect(step(set)["code_review"]["diagram"])
          .to eq("flowchart TD\n  A[Job] --> B[(DB)]")
      end

      it "drops an unusable diagram instead of persisting it" do
        [ "", "   ", nil, 42, [ "flowchart TD" ], "flowchart TD\n#{'x' * MermaidSource::MAX_LENGTH}",
          "sequenceDiagram\n  A->>B: hi", "flowchart TD\n  A --> B\n  classDef hot fill:#f00" ].each do |bad|
          set = { "pattern" => { "question" => "q", "diagram" => bad } }
          expect(step(set)["pattern"]).not_to have_key("diagram")
        end
      end

      it "strips a diagram the model volunteered for a non-diagrammable section" do
        set = { "security_review" => { "diagram" => "flowchart TD\n  A --> B" } }

        expect(step(set)["security_review"]).not_to have_key("diagram")
      end

      it "keeps a usable architecture reference diagram" do
        set = { "architecture" => { "reference" => { "diagram" => " flowchart TD\n  A --> B " } } }

        expect(step(set)["architecture"]["reference"]["diagram"])
          .to eq("flowchart TD\n  A --> B")
      end

      it "drops an architecture reference diagram MermaidSource refuses, keeping the rest of the reference" do
        [ "", "sequenceDiagram\n  A->>B: hi", "%%{init: {}}%%\nflowchart TD\n  A --> B" ].each do |bad|
          set = { "architecture" => { "reference" => { "tagline" => "t", "diagram" => bad } } }
          expect(step(set)["architecture"]["reference"]).to eq("tagline" => "t")
        end
      end

      it "leaves a section that carries no diagram alone" do
        set = { "pattern" => { "question" => "q" } }

        expect(step(set)).to eq("pattern" => { "question" => "q" })
      end
    end

  describe "the intended set as a contract" do
    let(:full_set) do
      {
        "code_review" => { "concept" => "n_plus_one" },
        "pattern"     => { "concept" => "memoization" }
      }
    end

    it "rejects a set missing an intended section, naming it" do
      expect {
        described_class.call(full_set.except("pattern"), language: "ruby_rails",
                             expected_keys: %w[code_review pattern])
      }.to raise_error(AiService::InvalidResponseError, /pattern/)
    end

    it "names every missing section, not just the first" do
      expect {
        described_class.call({}, language: "ruby_rails", expected_keys: %w[code_review pattern])
      }.to raise_error(AiService::InvalidResponseError, /code_review.*pattern/)
    end

    it "treats a non-Hash value as missing" do
      expect {
        described_class.call(full_set.merge("pattern" => "oops"), language: "ruby_rails",
                             expected_keys: %w[code_review pattern])
      }.to raise_error(AiService::InvalidResponseError, /pattern/)
    end

    it "accepts extra sections the day did not intend" do
      extra = full_set.merge("challenge" => { "concept" => "caching" })

      result = described_class.call(extra, language: "ruby_rails", expected_keys: %w[code_review pattern])

      expect(result.problem_set).to have_key("challenge")
    end

    it "warns when the provider returns a section the day did not intend" do
      extra = full_set.merge("challenge" => { "concept" => "caching" })

      expect(Rails.logger).to receive(:warn).with(/\[unrequested_sections\].*challenge/)

      described_class.call(extra, language: "ruby_rails", expected_keys: %w[code_review pattern])
    end

    it "names what was intended alongside what arrived unasked for" do
      extra = full_set.merge("challenge" => { "concept" => "caching" })

      expect(Rails.logger).to receive(:warn).with(/code_review.*pattern/)

      described_class.call(extra, language: "ruby_rails", expected_keys: %w[code_review pattern])
    end

    it "escapes a section name rather than letting it forge a log line" do
      forged = full_set.merge("challenge\nFATAL -- : owned" => { "concept" => "caching" })

      expect(Rails.logger).to receive(:warn) do |message|
        expect(message.lines.size).to eq(1)
        expect(message).to include('challenge\\nFATAL')
      end

      described_class.call(forged, language: "ruby_rails", expected_keys: %w[code_review pattern])
    end

    it "stays quiet when the delivered set is exactly the intended one" do
      expect(Rails.logger).not_to receive(:warn)

      described_class.call(full_set, language: "ruby_rails", expected_keys: %w[code_review pattern])
    end

    it "reports a missing section rather than its unusable answer key" do
      expect {
        described_class.call(full_set, language: "ruby_rails",
                             expected_keys: %w[code_review pattern ambiguity_hunt])
      }.to raise_error(AiService::InvalidResponseError, /ambiguity_hunt/)
    end
  end
end

RSpec.describe ProblemSetIngest, "formatting code" do
  def ingested(problem_set, language: "ruby_rails")
    described_class.call(problem_set, language: language, expected_keys: problem_set.keys).problem_set
  end

  before do
    allow(CodeFormat).to receive(:all) { |snippets, language:| snippets.map { |code| "#{language}: #{code}" } }
  end

  it "formats each kind's code fields in the day's language and nothing else" do
    set = FakeService::EXERCISE_PROBLEM_SET.deep_dup.slice("code_review", "challenge", "parsons_problem")
    set["challenge"]["starter_code"] = "function start() {}"
    original = set.deep_dup
    result = ingested(set, language: "javascript")

    expect(result["code_review"]["snippet"]).to eq("javascript: #{original['code_review']['snippet']}")
    expect(result["challenge"]["starter_code"]).to eq("javascript: function start() {}")
    expect(result["code_review"]["question"]).to eq(original["code_review"]["question"])
    expect(result["parsons_problem"].to_json).not_to include("javascript: ")
  end

  it "formats a design comparison's pieces before they are arranged" do
    pieces = FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison").values_at("better_piece", "other_piece")
    section = ingested({ "design_comparison" => FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison").deep_dup })["design_comparison"]

    expect([ section["piece_a"], section["piece_b"] ]).to contain_exactly(*pieces.map { |piece| "ruby_rails: #{piece}" })
  end

  it "formats before the boundary checks run" do
    allow(CodeFormat).to receive(:all) { |snippets, **| snippets.map { |code| "#{code}\n" + ("x\n" * 30) } }
    set = { "code_review" => { "concept" => "n_plus_one", "snippet" => "a" },
            "design_comparison" => FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison").deep_dup }

    result = described_class.call(set, language: "ruby_rails", expected_keys: set.keys)

    expect(result.unusable_sections.map(&:key)).to eq([ "design_comparison" ])
  end

  it "passes nothing when no section carries code" do
    ingested({ "pattern" => FakeService::EXERCISE_PROBLEM_SET.fetch("pattern").deep_dup })

    expect(CodeFormat).to have_received(:all).with([], language: "ruby_rails")
  end
end

RSpec.describe ProblemSetIngest, "pitched rung stamps" do
  let(:problem_set) do
    { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
      "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" } }
  end

  def ingest(set, pitched_at:, eased_for: {})
    described_class.call(set, language: "ruby_rails", expected_keys: set.keys,
                         pitched_at: pitched_at, eased_for: eased_for).problem_set
  end

  it "stamps every section with the rung it was pitched at" do
    result = ingest(problem_set, pitched_at: { "code_review" => "senior", "pattern" => "junior" })

    expect(result["code_review"]["pitched_at"]).to eq("senior")
    expect(result["pattern"]["pitched_at"]).to eq("junior")
  end

  it "replaces a provider-written rung and removes a provider-written eased flag" do
    set = problem_set.deep_dup
    set["code_review"].merge!("pitched_at" => "principal_engineer", "eased" => true)

    result = ingest(set, pitched_at: { "code_review" => "junior", "pattern" => "junior" })

    expect(result["code_review"]["pitched_at"]).to eq("junior")
    expect(result["code_review"]).not_to have_key("eased")
  end

  it "strips provider-written stamps from a section the day never asked for" do
    set = problem_set.merge("architecture" => { "question" => "q", "concept" => "sync_vs_async",
                                                "pitched_at" => "principal_engineer", "eased" => true })

    result = described_class.call(set, language: "ruby_rails", expected_keys: problem_set.keys,
                                  pitched_at: { "code_review" => "junior", "pattern" => "junior" }).problem_set

    expect(result["architecture"]).not_to have_key("pitched_at")
    expect(result["architecture"]).not_to have_key("eased")
  end

  it "strips a provider-written anchor marker and a stray source trace" do
    set = problem_set.deep_dup
    set["pattern"].merge!("anchored" => true, "source" => "forged-trace")

    result = ingest(set, pitched_at: { "code_review" => "junior", "pattern" => "junior" })

    expect(result["pattern"]).not_to have_key("anchored")
    expect(result["pattern"]).not_to have_key("source")
  end

  it "marks a section eased only when its concept is one the prompt was told to ease there" do
    result = ingest(problem_set, pitched_at: { "code_review" => "senior", "pattern" => "senior" },
                                 eased_for: { "code_review" => [ "n_plus_one" ], "pattern" => [ "n_plus_one" ] })

    expect(result["code_review"]["eased"]).to be(true)
    expect(result["pattern"]).not_to have_key("eased")
  end

  it "removes a provider-written eased flag even when no rung came with it" do
    set = problem_set.deep_dup
    set["code_review"]["eased"] = true

    result = ingest(set, pitched_at: { "code_review" => "junior", "pattern" => "junior" })

    expect(result["code_review"]).not_to have_key("eased")
  end

  it "stamps a section the day did not ask for when a rung is known for its kind, since it can still win its slot" do
    set = problem_set.merge("architecture" => { "question" => "q", "concept" => "sync_vs_async" })

    result = described_class.call(set, language: "ruby_rails", expected_keys: problem_set.keys,
                                  pitched_at: { "code_review" => "junior", "pattern" => "junior", "architecture" => "senior" }).problem_set

    expect(result["architecture"]["pitched_at"]).to eq("senior")
  end

  it "strips provider copies but stamps nothing when no rungs are given" do
    set = problem_set.deep_dup
    set["code_review"].merge!("pitched_at" => "senior", "eased" => true)

    result = described_class.call(set, language: "ruby_rails", expected_keys: set.keys).problem_set

    expect(result["code_review"]).not_to have_key("pitched_at")
    expect(result["code_review"]).not_to have_key("eased")
  end
end

RSpec.describe ProblemSetIngest, "fixed concepts on a retry" do
  let(:set) { { "challenge" => { "question" => "q", "starter_code" => "s", "concept" => "n_plus_one" } } }
  it "raises when the returned concept is not the fixed one, before normalization can hide it" do
    expect { described_class.call(set, language: "ruby_rails", expected_keys: [ "challenge" ], fixed_concepts: { "challenge" => "memoization" }) }
      .to raise_error(AiService::InvalidResponseError, /memoization/)
  end
  it "rejects a retry tagged with any different concept when n_plus_one was fixed" do
    mismatch = { "challenge" => set.fetch("challenge").merge("concept" => "memoization") }

    expect { described_class.call(mismatch, language: "ruby_rails", expected_keys: [ "challenge" ], fixed_concepts: { "challenge" => "n_plus_one" }) }
      .to raise_error(AiService::InvalidResponseError, /n_plus_one/)
  end
  it "drops sections the retry did not ask for instead of keeping them" do
    extra = set.merge("pattern" => { "question" => "q", "concept" => "memoization" })
    result = described_class.call(extra, language: "ruby_rails", expected_keys: [ "challenge" ], fixed_concepts: { "challenge" => "n_plus_one" }).problem_set
    expect(result.keys).to eq([ "challenge" ])
  end
end

RSpec.describe ProblemSetIngest, "with the second fixed kind" do
  describe "a design comparison" do
    def comparison(overrides = {})
      FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison").deep_dup.merge(overrides)
    end

    def ingested(problem_set)
      described_class.call(problem_set, language: "ruby_rails", expected_keys: problem_set.keys).problem_set
    end

    def roll_better(position)
      allow(WeightedRoll).to receive(:pick).with(ExerciseSection::DesignComparison::POSITION_WEIGHTS).and_return(position)
    end

    it "shows the provider's pieces in the rolled order and records the position only in the answer key" do
      roll_better("a")
      section = ingested({ "design_comparison" => comparison })["design_comparison"]

      expect(section["piece_a"]).to eq(comparison["better_piece"])
      expect(section["piece_b"]).to eq(comparison["other_piece"])
      expect(section["answer_key"]["better"]).to eq("a")
      expect(section).not_to have_key("better_piece")
      expect(section).not_to have_key("other_piece")
    end

    it "overwrites pieces the provider placed itself" do
      roll_better("b")
      forged = comparison("piece_a" => "forged", "piece_b" => "forged")
      section = ingested({ "design_comparison" => forged })["design_comparison"]

      expect(section["piece_b"]).to eq(comparison["better_piece"])
      expect(section["piece_a"]).to eq(comparison["other_piece"])
    end

    it "leaves the comparison out when a piece or the answer key is unusable" do
      { comparison("other_piece" => "") => /other_piece/, comparison("answer_key" => {}) => /answer key/ }.each do |section, reason|
        result = described_class.call({ "code_review" => { "concept" => "n_plus_one" }, "design_comparison" => section },
                                      language: "ruby_rails", expected_keys: %w[code_review design_comparison])

        expect(result.problem_set.keys).to eq([ "code_review" ])
        expect(result.unusable_sections.sole).to have_attributes(key: "design_comparison", concept: "open_closed", reason: reason)
      end
    end

    it "holds the concept to the language vocabulary like any other section" do
      expect(ingested({ "design_comparison" => comparison("concept" => "invented") })["design_comparison"]["concept"]).to eq("other")
    end
  end

  describe "a payload with a shape in every slot" do
    let(:every_kind) { FakeService::EXERCISE_PROBLEM_SET.deep_dup }

    it "drops the slots the plan left empty, so no requested section is cut" do
      expected = %w[code_review design_comparison challenge plan_review]
      result = described_class.call(every_kind, language: "ruby_rails", expected_keys: expected).problem_set

      expect(result.keys).not_to include("pattern")
      expect(ExerciseSection.resolved_keys(result)).to eq(%w[code_review design_comparison architecture plan_review])
      expect(ExerciseSection.resolved_keys(result).size).to eq(ExerciseSection::MAX_SECTIONS)
    end

    it "never delivers more than MAX_SECTIONS, whatever the plan asked for" do
      plans = [ %w[code_review design_comparison], %w[code_review design_comparison pattern],
                %w[code_review design_comparison pattern challenge], %w[code_review design_comparison ambiguity_hunt] ]

      plans.each do |expected|
        result = described_class.call(FakeService::EXERCISE_PROBLEM_SET.deep_dup, language: "ruby_rails",
                                      expected_keys: expected).problem_set
        expect(ExerciseSection.resolved_keys(result).size).to be <= ExerciseSection::MAX_SECTIONS
        expect(ExerciseSection.resolved_keys(result).first(2)).to eq(%w[code_review design_comparison])
      end
    end

    it "keeps an unrequested extra when the day still has room" do
      set = { "code_review" => { "concept" => "n_plus_one" }, "pattern" => { "concept" => "memoization" } }
      result = described_class.call(set, language: "ruby_rails", expected_keys: [ "code_review" ]).problem_set

      expect(result.keys).to eq(%w[code_review pattern])
    end
  end
end
