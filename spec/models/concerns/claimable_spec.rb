require "rails_helper"

RSpec.describe Claimable do
  let(:user) { User.create!(email: "claimable-#{SecureRandom.hex(3)}@example.com", name: "C") }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
  end
  let(:response) { DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {}) }
  let(:stale) { (DailyResponse::REVIEW_CLAIM_STALE_AFTER + 1.minute).ago }

  describe "taking a claim" do
    it "returns the stored timestamp as the token, and the claim is held" do
      token = response.claim_reviewing!

      expect(token).to be_present
      expect(response.reload.reviewing_since).to eq(token)
      expect(response).to be_reviewing
    end

    it "refuses while another claim is fresh" do
      response.claim_reviewing!

      expect(DailyResponse.find(response.id).claim_reviewing!).to be_nil
    end

    it "takes over a stale claim" do
      response.update_column(:reviewing_since, stale)

      expect(response.claim_reviewing!).to be_present
    end

    it "refuses when the extra conditions do not hold" do
      exercise.update_column(:regenerated_at, Time.current)

      expect(exercise.claim_regenerating!(regenerated_at: nil)).to be_nil
      expect(exercise.reload.regenerating_since).to be_nil
    end
  end

  describe "releasing a claim" do
    it "clears the caller's own claim" do
      token = response.claim_reviewing!
      response.release_reviewing!(token)

      expect(response.reload.reviewing_since).to be_nil
      expect(response).not_to be_reviewing
    end

    it "leaves a claim taken over after the caller's went stale" do
      response.update_column(:reviewing_since, stale)
      overrun = response.reload.reviewing_since
      current = DailyResponse.find(response.id).claim_reviewing!

      response.release_reviewing!(overrun)

      expect(response.reload.reviewing_since).to eq(current)
    end
  end

  it "applies one staleness rule to the predicate and to taking a claim" do
    response.update_column(:reviewing_since, (DailyResponse::REVIEW_CLAIM_STALE_AFTER - 1.minute).ago)
    expect(response.reload).to be_reviewing
    expect(response.claim_reviewing!).to be_nil

    response.update_column(:reviewing_since, stale)
    expect(response.reload).not_to be_reviewing
    expect(response.claim_reviewing!).to be_present
  end

  it "gives each model its own window" do
    exercise.update_column(:regenerating_since, (DailyExercise::REGENERATION_STALE_AFTER + 1.minute).ago)

    expect(exercise.reload).not_to be_regenerating
    expect(exercise.claim_regenerating!(regenerated_at: nil)).to be_present
  end
end
