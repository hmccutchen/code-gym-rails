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

  describe "#first_exposure?" do
    let(:user) { create_user_with_key }

    before do
      current_user = user
      helper.define_singleton_method(:current_user) { current_user }
    end

    it "returns false for a blank concept" do
      expect(helper.first_exposure?(nil, "ruby_rails", Date.current)).to eq(false)
      expect(helper.first_exposure?("", "ruby_rails", Date.current)).to eq(false)
    end

    it "returns false for the 'other' concept" do
      expect(helper.first_exposure?("other", "ruby_rails", Date.current)).to eq(false)
    end

    it "returns true when the user has no prior exposure to the concept in that bucket" do
      expect(helper.first_exposure?("n_plus_one", "ruby_rails", Date.current)).to eq(true)
    end

    it "returns false once the user has a prior submitted exposure to the concept" do
      exercise = DailyExercise.create!(user: user, date: Date.current - 1, language: "ruby_rails",
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            concept_tags: { "code_review" => "n_plus_one" })

      expect(helper.first_exposure?("n_plus_one", "ruby_rails", Date.current)).to eq(false)
    end

    it "scopes exposure by bucket" do
      exercise = DailyExercise.create!(user: user, date: Date.current - 1, language: "javascript",
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            concept_tags: { "code_review" => "closures" })

      expect(helper.first_exposure?("closures", "javascript", Date.current)).to eq(false)
      expect(helper.first_exposure?("closures", "ruby_rails", Date.current)).to eq(true)
    end
  end
end
