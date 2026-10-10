require "rails_helper"

RSpec.describe ConceptVocabulary do
  describe ".for_language" do
    it "resolves the fourth-slot buckets like architecture" do
      expect(described_class.for_language("plan_review")).to eq(described_class::PLAN_REVIEW_CONCEPTS)
      expect(described_class.for_language("ambiguity_hunt")).to eq(described_class::AMBIGUITY_HUNT_CONCEPTS)
    end

    it "raises instead of falling back on an unsupported language" do
      expect { described_class.for_language("mixed") }
        .to raise_error(described_class::UnknownLanguage, /Unsupported generation language: "mixed"/)
    end
  end

  describe ".language_agnostic?" do
    it "is true for the buckets with no code of their own and false for the two languages" do
      expect(%w[architecture plan_review ambiguity_hunt pseudocode_to_code].map { |bucket| described_class.language_agnostic?(bucket) })
        .to all(be true)
      expect(%w[ruby_rails javascript].map { |language| described_class.language_agnostic?(language) }).to all(be false)
    end
  end

  it "resolves every registered kind in both languages" do
    ExerciseSection.all.each do |kind|
      %w[ruby_rails javascript].each do |language|
        expect(described_class.for_section(kind.key, language)).to be_present, "#{kind.key} in #{language}"
      end
    end
  end

  it "has a group for every excluded group a kind names" do
    named = ExerciseSection.all.flat_map(&:excluded_vocabulary_keys).uniq

    expect(named - described_class::GROUPS.keys).to be_empty
  end

  describe "RAILS_CONCEPTS" do
    it "is a frozen 44-entry vocabulary" do
      expect(ConceptVocabulary::RAILS_CONCEPTS.size).to eq(44)
      expect(ConceptVocabulary::RAILS_CONCEPTS).to be_frozen
      expect(ConceptVocabulary::RAILS_CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end

    it "includes the two Rails security concepts chosen for real depth" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).to include("mass_assignment_protection", "sql_injection_prevention")
    end

    it "includes the two test-analysis concepts added for code_review's occasional test-file variant" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).to include("over_mocking", "testing_implementation_not_behavior")
    end

    it "excludes secure_secrets_handling and dependency_vulnerability_management as poor fits for this app's format" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).not_to include("secure_secrets_handling", "dependency_vulnerability_management")
    end
  end

  describe "JS_CONCEPTS" do
    it "is a frozen 46-entry vocabulary" do
      expect(ConceptVocabulary::JS_CONCEPTS.size).to eq(46)
      expect(ConceptVocabulary::JS_CONCEPTS).to be_frozen
      expect(ConceptVocabulary::JS_CONCEPTS).to include("closures", "prototype_chain", "hooks_dependencies")
    end

    it "includes the two JS security concepts chosen for real depth" do
      expect(ConceptVocabulary::JS_CONCEPTS).to include("xss_prevention", "insecure_client_storage")
    end

    it "includes the two test-analysis concepts added for code_review's occasional test-file variant" do
      expect(ConceptVocabulary::JS_CONCEPTS).to include("over_mocking", "testing_implementation_not_behavior")
    end
  end

  describe "CODE_SMELL_CONCEPTS" do
    it "names smells rather than the remedies the vocabularies already carry" do
      expect(ConceptVocabulary::CODE_SMELL_CONCEPTS)
        .to contain_exactly("god_object", "primitive_obsession", "shotgun_surgery", "feature_envy")
      expect(ConceptVocabulary::CODE_SMELL_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).to include(*ConceptVocabulary::CODE_SMELL_CONCEPTS)
      expect(ConceptVocabulary::JS_CONCEPTS).to include(*ConceptVocabulary::CODE_SMELL_CONCEPTS)
    end
  end

  describe "OO_DESIGN_CONCEPTS" do
    it "names the three principles that survived the depth and relevance filters" do
      expect(ConceptVocabulary::OO_DESIGN_CONCEPTS)
        .to contain_exactly("open_closed", "dependency_inversion", "composition_over_inheritance")
      expect(ConceptVocabulary::OO_DESIGN_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).to include(*ConceptVocabulary::OO_DESIGN_CONCEPTS)
      expect(ConceptVocabulary::JS_CONCEPTS).to include(*ConceptVocabulary::OO_DESIGN_CONCEPTS)
    end

    it "omits the candidates that duplicated an existing concept or failed the relevance filter" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).not_to include(
        "single_responsibility", "program_to_interface", "encapsulate_what_varies",
        "liskov_substitution", "interface_segregation"
      )
      expect(ConceptVocabulary::JS_CONCEPTS).not_to include(
        "single_responsibility", "program_to_interface", "encapsulate_what_varies",
        "liskov_substitution", "interface_segregation"
      )
    end

    it "stays out of the language-agnostic vocabularies, so its references show real code" do
      ConceptVocabulary::LANGUAGE_AGNOSTIC_VOCABULARIES.each do |vocabulary|
        expect(vocabulary).not_to include(*ConceptVocabulary::OO_DESIGN_CONCEPTS)
      end
    end
  end

  describe "MODULE_DESIGN_CONCEPTS" do
    it "names the three module-design shapes that survived the overlap filter" do
      expect(ConceptVocabulary::MODULE_DESIGN_CONCEPTS)
        .to contain_exactly("shallow_module", "pass_through_method", "temporal_decomposition")
      expect(ConceptVocabulary::MODULE_DESIGN_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).to include(*ConceptVocabulary::MODULE_DESIGN_CONCEPTS)
      expect(ConceptVocabulary::JS_CONCEPTS).to include(*ConceptVocabulary::MODULE_DESIGN_CONCEPTS)
    end

    it "omits the candidates that duplicated an existing concept" do
      %w[information_leakage special_general_mixture].each do |cut|
        expect(ConceptVocabulary::RAILS_CONCEPTS).not_to include(cut)
        expect(ConceptVocabulary::JS_CONCEPTS).not_to include(cut)
      end
    end

    it "stays out of the language-agnostic vocabularies, so its references show real code" do
      ConceptVocabulary::LANGUAGE_AGNOSTIC_VOCABULARIES.each do |vocabulary|
        expect(vocabulary).not_to include(*ConceptVocabulary::MODULE_DESIGN_CONCEPTS)
      end
    end
  end

  describe "SILENT_CORRECTNESS_CONCEPTS" do
    it "names the four invariant defects that survived the overlap filter" do
      expect(ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS)
        .to contain_exactly("allocation_rounding", "semantic_input_validation",
                            "cache_key_completeness", "deterministic_ordering")
      expect(ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS).to be_frozen
    end

    it "is reachable from both language vocabularies" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS)
      expect(ConceptVocabulary::JS_CONCEPTS).to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS)
    end

    it "stays out of the language-agnostic vocabularies, so its references show real code" do
      ConceptVocabulary::LANGUAGE_AGNOSTIC_VOCABULARIES.each do |vocabulary|
        expect(vocabulary).not_to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS)
      end
    end

    it "stays off the anti-shape list, so its reference keeps the remedy lens" do
      expect(ConceptVocabulary::ANTI_SHAPE_CONCEPTS).not_to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS)
    end

    it "shares no entry with the fourth-slot or architecture vocabularies" do
      [ ConceptVocabulary::ARCHITECTURE_CONCEPTS, ConceptVocabulary::PLAN_REVIEW_CONCEPTS,
        ConceptVocabulary::AMBIGUITY_HUNT_CONCEPTS, ConceptVocabulary::PSEUDOCODE_TO_CODE_CONCEPTS ].each do |vocabulary|
        expect(vocabulary & ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS).to be_empty
      end
    end
  end

  describe "TYPESCRIPT_FLAVORED_CONCEPTS" do
    it "is a frozen 4-entry subset of JS_CONCEPTS" do
      expect(ConceptVocabulary::TYPESCRIPT_FLAVORED_CONCEPTS.size).to eq(4)
      expect(ConceptVocabulary::TYPESCRIPT_FLAVORED_CONCEPTS).to be_frozen
      expect(ConceptVocabulary::TYPESCRIPT_FLAVORED_CONCEPTS - ConceptVocabulary::JS_CONCEPTS).to be_empty
      expect(ConceptVocabulary::TYPESCRIPT_FLAVORED_CONCEPTS).to contain_exactly(
        "generics", "type_guards_narrowing", "union_intersection_types", "mapped_conditional_types"
      )
    end
  end

  describe "DATA_MODELING_CONCEPTS" do
    it "holds the five data-modeling concepts" do
      expect(ConceptVocabulary::DATA_MODELING_CONCEPTS).to eq(%w[
        missing_index wrong_cardinality missing_constraint
        denormalization_tradeoffs unsafe_migration
      ])
    end

    it "is frozen" do
      expect(ConceptVocabulary::DATA_MODELING_CONCEPTS).to be_frozen
    end

    it "overlaps no other closed vocabulary" do
      [ ConceptVocabulary::ARCHITECTURE_CONCEPTS, ConceptVocabulary::PLAN_REVIEW_CONCEPTS,
        ConceptVocabulary::AMBIGUITY_HUNT_CONCEPTS, ConceptVocabulary::RAILS_SECURITY_CONCEPTS,
        ConceptVocabulary::JS_SECURITY_CONCEPTS ].each do |other|
        expect(ConceptVocabulary::DATA_MODELING_CONCEPTS & other).to be_empty
      end
    end

    it "is folded into both language vocabularies, which stay frozen" do
      expect(ConceptVocabulary::RAILS_CONCEPTS).to include(*ConceptVocabulary::DATA_MODELING_CONCEPTS)
      expect(ConceptVocabulary::JS_CONCEPTS).to include(*ConceptVocabulary::DATA_MODELING_CONCEPTS)
      expect(ConceptVocabulary::RAILS_CONCEPTS).to be_frozen
      expect(ConceptVocabulary::JS_CONCEPTS).to be_frozen
    end
  end

  describe "TRADEOFF_CONCEPTS" do
    it "excludes the architecture concepts that name a cause of complexity rather than a decision" do
      expect(ConceptVocabulary::TRADEOFF_CONCEPTS & ConceptVocabulary::COMPLEXITY_CAUSE_CONCEPTS).to be_empty
    end

    it "is disjoint from every anti-shape concept" do
      expect(ConceptVocabulary::TRADEOFF_CONCEPTS & ConceptVocabulary::ANTI_SHAPE_CONCEPTS).to be_empty
    end

    it "names only concepts that exist in a tracked vocabulary" do
      tracked = ConceptVocabulary::RAILS_CONCEPTS + ConceptVocabulary::JS_CONCEPTS + ConceptVocabulary::ARCHITECTURE_CONCEPTS
      expect(ConceptVocabulary::TRADEOFF_CONCEPTS - tracked).to be_empty
    end

    it "holds every architecture concept to a deliberate classification" do
      unclassified =
        ConceptVocabulary::ARCHITECTURE_CONCEPTS - ConceptVocabulary::TRADEOFF_CONCEPTS - ConceptVocabulary::COMPLEXITY_CAUSE_CONCEPTS

      expect(unclassified).to be_empty
    end
  end

  describe ".selectable_for_section" do
    it "hands the kind's own hook what the excluded groups left, with the rung" do
      after_exclusions = described_class.selectable_for_section("parsons_problem", "ruby_rails")
      allow(ExerciseSection::ParsonsProblem).to receive(:narrow_vocabulary).and_return(%w[n_plus_one])

      vocabulary = described_class.selectable_for_section("parsons_problem", "ruby_rails", rung: "senior")

      expect(vocabulary).to eq(%w[n_plus_one])
      expect(ExerciseSection::ParsonsProblem).to have_received(:narrow_vocabulary)
        .with(after_exclusions, rung: "senior")
    end

    it "passes no rung when the caller names none" do
      allow(ExerciseSection::Pattern).to receive(:narrow_vocabulary).and_call_original

      described_class.selectable_for_section("pattern", "ruby_rails")

      expect(ExerciseSection::Pattern).to have_received(:narrow_vocabulary).with(ConceptVocabulary::RAILS_CONCEPTS, rung: nil)
    end

    it "withholds every data-modeling concept from parsons_problem" do
      vocabulary = described_class.selectable_for_section("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*ConceptVocabulary::DATA_MODELING_CONCEPTS)
      expect(vocabulary).to include("n_plus_one")
    end

    it "withholds them in both languages" do
      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_for_section("parsons_problem", language))
          .not_to include(*ConceptVocabulary::DATA_MODELING_CONCEPTS)
      end
    end

    it "changes nothing about parsons beyond the exclusion" do
      excluded = ConceptVocabulary::DATA_MODELING_CONCEPTS + ConceptVocabulary::DOMAIN_MODELING_CONCEPTS +
                 ConceptVocabulary::META_SKILL_CONCEPTS +
                 ConceptVocabulary::CODE_SMELL_CONCEPTS + ConceptVocabulary::OO_DESIGN_CONCEPTS +
                 ConceptVocabulary::MODULE_DESIGN_CONCEPTS + ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS

      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_for_section("parsons_problem", language))
          .to eq(described_class.selectable_for_section("challenge", language) - excluded)
      end
    end

    it "leaves every other kind's selectable vocabulary alone" do
      %w[pattern challenge security_review architecture plan_review ambiguity_hunt].each do |key|
        expect(described_class.selectable_for_section(key, "ruby_rails"))
          .to eq(described_class.for_section(key, "ruby_rails")), "#{key} was narrowed unexpectedly"
      end
    end

    it "still narrows code_review by its content mode" do
      expect(described_class.selectable_for_section("code_review", "ruby_rails", mode: :schema_review))
        .to eq(ConceptVocabulary::DATA_MODELING_CONCEPTS)
    end

    it "withholds every meta-skill concept from parsons_problem in both languages" do
      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_for_section("parsons_problem", language))
          .not_to include(*ConceptVocabulary::META_SKILL_CONCEPTS)
      end
    end

    it "offers the meta-skill concepts to code_review, pattern, and challenge" do
      %w[ruby_rails javascript].each do |language|
        %w[pattern challenge].each do |key|
          expect(described_class.selectable_for_section(key, language))
            .to include(*ConceptVocabulary::META_SKILL_CONCEPTS), "#{key}/#{language} was missing the group"
        end

        %i[application_code test_file].each do |mode|
          expect(described_class.selectable_for_section("code_review", language, mode: mode))
            .to include(*ConceptVocabulary::META_SKILL_CONCEPTS)
        end
      end
    end

    it "withholds them from the kinds whose own vocabulary is disjoint" do
      %w[security_review architecture plan_review ambiguity_hunt].each do |key|
        expect(described_class.selectable_for_section(key, "ruby_rails"))
          .not_to include(*ConceptVocabulary::META_SKILL_CONCEPTS), "#{key} could be offered a meta-skill concept"
      end
    end

    it "withholds code smells from parsons_problem, whose format has nothing to recognize" do
      vocabulary = described_class.selectable_for_section("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*ConceptVocabulary::CODE_SMELL_CONCEPTS)
    end

    it "offers code smells to code_review outside schema-review mode" do
      vocabulary = described_class.selectable_for_section("code_review", "ruby_rails", mode: :application_code)

      expect(vocabulary).to include(*ConceptVocabulary::CODE_SMELL_CONCEPTS)
    end

    it "withholds code smells from a schema-review code_review" do
      vocabulary = described_class.selectable_for_section("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*ConceptVocabulary::CODE_SMELL_CONCEPTS)
    end

    it "withholds OO design principles from parsons_problem, whose grade is an ordering" do
      vocabulary = described_class.selectable_for_section("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*ConceptVocabulary::OO_DESIGN_CONCEPTS)
    end

    it "withholds module-design concepts from parsons_problem, whose grade is an ordering" do
      vocabulary = described_class.selectable_for_section("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*ConceptVocabulary::MODULE_DESIGN_CONCEPTS)
    end

    it "offers module-design concepts to code_review outside schema-review mode" do
      vocabulary = described_class.selectable_for_section("code_review", "javascript", mode: :application_code)

      expect(vocabulary).to include(*ConceptVocabulary::MODULE_DESIGN_CONCEPTS)
    end

    it "offers OO design principles to code_review outside schema-review mode" do
      vocabulary = described_class.selectable_for_section("code_review", "javascript", mode: :application_code)

      expect(vocabulary).to include(*ConceptVocabulary::OO_DESIGN_CONCEPTS)
    end

    # AiService#oo_design_violation_guidance's test-file idiom assumes this; revisit it if selection narrows.
    it "offers every OO design principle to a test-file code_review" do
      vocabulary = described_class.selectable_for_section("code_review", "ruby_rails", mode: :test_file)

      expect(vocabulary).to include(*ConceptVocabulary::OO_DESIGN_CONCEPTS)
    end

    it "withholds OO design principles from a schema-review code_review" do
      vocabulary = described_class.selectable_for_section("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*ConceptVocabulary::OO_DESIGN_CONCEPTS)
    end

    it "withholds silent-correctness concepts from parsons_problem, whose grade is an ordering" do
      vocabulary = described_class.selectable_for_section("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS)
    end

    it "offers silent-correctness concepts to code_review, pattern, and challenge in both languages" do
      %w[ruby_rails javascript].each do |language|
        %w[pattern challenge].each do |key|
          expect(described_class.selectable_for_section(key, language))
            .to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS), "#{key}/#{language} was missing the group"
        end

        %i[application_code test_file].each do |mode|
          expect(described_class.selectable_for_section("code_review", language, mode: mode))
            .to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS), "code_review/#{mode}/#{language} was missing the group"
        end
      end
    end

    it "withholds silent-correctness concepts from a schema-review code_review" do
      vocabulary = described_class.selectable_for_section("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS)
    end

    it "withholds them from the kinds whose own vocabulary is disjoint" do
      %w[security_review architecture plan_review ambiguity_hunt pseudocode_to_code].each do |key|
        expect(described_class.selectable_for_section(key, "ruby_rails"))
          .not_to include(*ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS), "#{key} could be offered a silent-correctness concept"
      end
    end

    it "withholds domain-modeling concepts from parsons_problem, whose positional grade cannot measure naming or write paths" do
      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_for_section("parsons_problem", language))
          .not_to include(*ConceptVocabulary::DOMAIN_MODELING_CONCEPTS)
      end
    end

    it "offers domain-modeling concepts to code_review, pattern, and challenge in both languages" do
      %w[ruby_rails javascript].each do |language|
        %w[pattern challenge].each do |key|
          expect(described_class.selectable_for_section(key, language))
            .to include(*ConceptVocabulary::DOMAIN_MODELING_CONCEPTS), "#{key}/#{language} was missing the group"
        end

        %i[application_code test_file].each do |mode|
          expect(described_class.selectable_for_section("code_review", language, mode: mode))
            .to include(*ConceptVocabulary::DOMAIN_MODELING_CONCEPTS), "code_review/#{mode}/#{language} was missing the group"
        end
      end
    end

    it "withholds domain-modeling concepts from a schema-review code_review" do
      vocabulary = described_class.selectable_for_section("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*ConceptVocabulary::DOMAIN_MODELING_CONCEPTS)
    end

    it "withholds domain-modeling concepts from the kinds whose own vocabulary is disjoint" do
      %w[security_review architecture plan_review ambiguity_hunt pseudocode_to_code].each do |key|
        expect(described_class.selectable_for_section(key, "ruby_rails"))
          .not_to include(*ConceptVocabulary::DOMAIN_MODELING_CONCEPTS), "#{key} could be offered a domain-modeling concept"
      end
    end
  end

  describe ".for_section" do
    it "resolves each kind's vocabulary through its vocabulary_key" do
      expect(described_class.for_section("code_review", "ruby_rails")).to eq(ConceptVocabulary::RAILS_CONCEPTS)
      expect(described_class.for_section("code_review", "javascript")).to eq(ConceptVocabulary::JS_CONCEPTS)
      expect(described_class.for_section("architecture", "ruby_rails")).to eq(ConceptVocabulary::ARCHITECTURE_CONCEPTS)
      expect(described_class.for_section("security_review", "ruby_rails")).to eq(ConceptVocabulary::RAILS_SECURITY_CONCEPTS)
      expect(described_class.for_section("plan_review", "ruby_rails")).to eq(ConceptVocabulary::PLAN_REVIEW_CONCEPTS)
      expect(described_class.for_section("ambiguity_hunt", "ruby_rails")).to eq(ConceptVocabulary::AMBIGUITY_HUNT_CONCEPTS)
    end

    it "still accepts a data-modeling concept tagged on parsons_problem" do
      expect(described_class.for_section("parsons_problem", "ruby_rails")).to include("missing_index")
    end

    it "falls back to the language vocabulary for a section key a provider invented" do
      expect(described_class.for_section("made_up_section", "ruby_rails")).to eq(ConceptVocabulary::RAILS_CONCEPTS)
    end

    it "returns the full language vocabulary for code_review with no mode, since ingest cannot tell which mode produced a set" do
      expect(described_class.for_section("code_review", "ruby_rails"))
        .to eq(ConceptVocabulary::RAILS_CONCEPTS)
    end

    it "narrows code_review to the data-modeling concepts on a schema-review day" do
      expect(described_class.selectable_for_section("code_review", "ruby_rails", mode: :schema_review))
        .to eq(ConceptVocabulary::DATA_MODELING_CONCEPTS)
    end

    it "excludes the data-modeling concepts on the other two modes" do
      %i[application_code test_file].each do |mode|
        vocabulary = described_class.selectable_for_section("code_review", "ruby_rails", mode: mode)
        expect(vocabulary).not_to include(*ConceptVocabulary::DATA_MODELING_CONCEPTS)
        expect(vocabulary).to include("n_plus_one")
      end
    end

    it "leaves pattern unnarrowed on every mode" do
      %i[application_code test_file schema_review].each do |mode|
        expect(described_class.selectable_for_section("pattern", "ruby_rails", mode: mode))
          .to eq(ConceptVocabulary::RAILS_CONCEPTS)
      end
    end
  end
end
