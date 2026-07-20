require "rails_helper"

RSpec.describe ConceptReferencesHelper, type: :helper do
  describe "#concept_reference_for" do
    it "returns the cached reference for the concept in the given language" do
      ref = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "npo")
      expect(helper.concept_reference_for("n_plus_one", "ruby_rails")).to eq(ref)
    end

    it "returns nil when no reference is cached for that concept" do
      expect(helper.concept_reference_for("n_plus_one", "ruby_rails")).to be_nil
    end

    it "scopes the lookup by language" do
      ConceptReference.create!(concept: "closures", language: "javascript", tagline: "js")
      expect(helper.concept_reference_for("closures", "ruby_rails")).to be_nil
      expect(helper.concept_reference_for("closures", "javascript")).not_to be_nil
    end

    it "returns nil for a blank concept without querying" do
      expect(helper.concept_reference_for(nil, "ruby_rails")).to be_nil
      expect(helper.concept_reference_for("", "ruby_rails")).to be_nil
    end
  end
end
