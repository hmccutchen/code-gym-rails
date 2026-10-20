require "rails_helper"

RSpec.describe LanguagePrompts do
  it "has prompt wording for exactly the languages ConceptVocabulary has lists for" do
    expect(described_class::ALL.keys).to match_array(ConceptVocabulary.languages)
  end

  describe "schema_artifact" do
    it "names a per-language artifact for the two real languages" do
      expect(described_class::ALL["ruby_rails"][:schema_artifact]).to eq("a Rails migration")
      expect(described_class::ALL["javascript"][:schema_artifact])
        .to eq("a Prisma schema change, with the migration it generates")
    end

    it "is absent for the pseudo-language buckets" do
      %w[architecture plan_review ambiguity_hunt].each do |bucket|
        expect(described_class::ALL[bucket][:schema_artifact]).to be_nil
      end
    end
  end

  it "raises a setup problem, not a provider failure, on an unsupported language" do
    expect { described_class.for("mixed") }.to raise_error(SetupError, /Unsupported generation language: "mixed"/)
  end
end
