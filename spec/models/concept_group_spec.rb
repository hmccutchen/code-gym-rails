require "rails_helper"

RSpec.describe ConceptGroup do
  describe ".for" do
    it "places a base-vocabulary concept in core" do
      expect(described_class.for("n_plus_one")).to eq(described_class::CORE)
    end

    it "places a named-group concept in its own group" do
      expect(described_class.for("god_object")).to eq("code_smell")
      expect(described_class.for("open_closed")).to eq("oo_design")
      expect(described_class.for("shallow_module")).to eq("module_design")
      expect(described_class.for("missing_index")).to eq("data_modeling")
      expect(described_class.for("reading_for_intent")).to eq("meta_skill")
    end

    it "places an unrecognized concept in core rather than raising" do
      expect(described_class.for("not_a_real_concept")).to eq(described_class::CORE)
    end
  end

  describe ".grouped" do
    it "returns groups in ORDER, omitting empty ones" do
      grouped = described_class.grouped(%w[god_object n_plus_one missing_index])

      expect(grouped.map(&:first)).to eq([ described_class::CORE, "data_modeling", "code_smell" ])
      expect(grouped.to_h["code_smell"]).to eq([ "god_object" ])
    end

    it "returns one flat core group for a language-independent bucket" do
      grouped = described_class.grouped(AiService::PLAN_REVIEW_CONCEPTS)

      expect(grouped.size).to eq(1)
      expect(grouped.first.first).to eq(described_class::CORE)
      expect(grouped.first.last).to match_array(AiService::PLAN_REVIEW_CONCEPTS)
    end

    it "preserves the vocabulary's own order inside a group" do
      expect(described_class.grouped(AiService::CODE_SMELL_CONCEPTS).first.last)
        .to eq(AiService::CODE_SMELL_CONCEPTS)
    end
  end

  describe "coverage of the language vocabularies" do
    # Constants that are strict subsets of a language vocabulary for reasons
    # other than display grouping: the two security lists narrow what
    # security_review may draw from, and TYPESCRIPT_FLAVORED_CONCEPTS switches
    # a section's syntax. A new one has to be named here deliberately.
    NON_GROUPING_SUBSETS = %i[
      RAILS_SECURITY_CONCEPTS JS_SECURITY_CONCEPTS TYPESCRIPT_FLAVORED_CONCEPTS
    ].freeze

    %w[ruby_rails javascript].each do |language|
      it "partitions every #{language} concept without loss or duplication" do
        concepts = ConceptBucket.vocabulary_for(language)

        expect(described_class.grouped(concepts).flat_map(&:last)).to match_array(concepts)
      end

      # The partition test above cannot catch this: an unregistered group's
      # concepts still come back, silently under CORE. Reflecting over
      # AiService's own group constants is what makes the omission loud.
      it "registers every group constant #{language} folds in" do
        vocabulary = ConceptBucket.vocabulary_for(language)
        registered = described_class::NAMED.map(&:last)

        unregistered = AiService.constants.grep(/_CONCEPTS\z/).reject do |name|
          next true if NON_GROUPING_SUBSETS.include?(name)

          concepts = AiService.const_get(name)
          next true unless concepts.is_a?(Array) && concepts.any?
          next true unless concepts.size < vocabulary.size && concepts.all? { |c| vocabulary.include?(c) }

          registered.include?(concepts)
        end

        expect(unregistered).to be_empty,
          "#{unregistered.join(', ')} folds into #{language} but has no ConceptGroup display group"
      end
    end
  end
end
