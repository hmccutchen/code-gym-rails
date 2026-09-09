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

  # This is what catches a language vocabulary growing a new named constant
  # without a display group to render it in: the new concepts would silently
  # land in core rather than failing.
  describe "coverage of the language vocabularies" do
    %w[ruby_rails javascript].each do |language|
      it "assigns every #{language} concept to exactly one group" do
        concepts = ConceptBucket.vocabulary_for(language)
        grouped  = described_class.grouped(concepts)

        expect(grouped.flat_map(&:last)).to match_array(concepts)
      end
    end

    it "keeps every named group non-empty in both language vocabularies" do
      described_class::NAMED.each do |key, group_concepts|
        expect(group_concepts).not_to be_empty, "#{key} is an empty display group"
        expect(ConceptBucket.vocabulary_for("ruby_rails")).to include(*group_concepts)
      end
    end
  end
end
