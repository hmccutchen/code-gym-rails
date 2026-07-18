require "rails_helper"

RSpec.describe ConceptReferencesHelper, type: :helper do
  let(:user) { User.create!(email: "help@example.com", name: "Help") }

  def exercise(language: "ruby_rails")
    DailyExercise.create!(
      user: user, date: Date.current - rand(1..9000).days,
      problem_set: { "code_review" => {} }, generated_at: Time.current, language: language
    )
  end

  def submitted_response(tags, date:, ex: exercise)
    DailyResponse.create!(
      user: user, daily_exercise: ex, date: date,
      concept_tags: tags, answers: {}, submitted_at: Time.current
    )
  end

  def draft_response(tags, date:, ex: exercise)
    DailyResponse.create!(
      user: user, daily_exercise: ex, date: date,
      concept_tags: tags, answers: {}, submitted_at: nil
    )
  end

  describe "#concept_exposure_count" do
    it "counts submitted responses whose concept_tags values include the concept" do
      submitted_response({ "code_review" => "n_plus_one" }, date: Date.current - 2)
      submitted_response({ "pattern" => "n_plus_one" }, date: Date.current - 1)
      expect(helper.concept_exposure_count(user, "n_plus_one")).to eq(2)
    end

    it "counts a concept appearing in two sections of one response as a single exposure" do
      submitted_response({ "code_review" => "n_plus_one", "challenge" => "n_plus_one" }, date: Date.current)
      expect(helper.concept_exposure_count(user, "n_plus_one")).to eq(1)
    end

    it "excludes unsubmitted drafts even if their concept_tags are populated" do
      draft_response({ "code_review" => "n_plus_one" }, date: Date.current)
      expect(helper.concept_exposure_count(user, "n_plus_one")).to eq(0)
    end

    it "returns 0 for a concept the user has never been tagged with" do
      submitted_response({ "code_review" => "memoization" }, date: Date.current)
      expect(helper.concept_exposure_count(user, "n_plus_one")).to eq(0)
    end
  end

  describe "#concept_references_for" do
    it "returns a reference + inclusive count per distinct cached concept" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "npo")
      ex = exercise
      resp = submitted_response({ "code_review" => "n_plus_one", "pattern" => "n_plus_one" }, date: Date.current, ex: ex)

      result = helper.concept_references_for(resp)
      expect(result.size).to eq(1)
      expect(result.first[:concept]).to eq("n_plus_one")
      expect(result.first[:reference].tagline).to eq("npo")
      expect(result.first[:count]).to eq(1)
    end

    it "skips concepts that have no cached reference" do
      resp = submitted_response({ "code_review" => "n_plus_one" }, date: Date.current)
      expect(helper.concept_references_for(resp)).to eq([])
    end

    it "matches the reference in the exercise's language" do
      ConceptReference.create!(concept: "closures", language: "javascript", tagline: "js")
      ex = exercise(language: "javascript")
      resp = submitted_response({ "code_review" => "closures" }, date: Date.current, ex: ex)
      result = helper.concept_references_for(resp)
      expect(result.size).to eq(1)
      expect(result.first[:reference].language).to eq("javascript")
    end

    it "returns [] when concept_tags is empty (predates the feature)" do
      resp = submitted_response({}, date: Date.current)
      expect(helper.concept_references_for(resp)).to eq([])
    end
  end
end
