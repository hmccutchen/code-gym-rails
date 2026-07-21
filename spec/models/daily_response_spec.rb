require "rails_helper"

RSpec.describe DailyResponse, type: :model do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  let(:exercise) do
    user.daily_exercises.create!(
      date: Date.current,
      generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
    )
  end

  describe "#answered_sections" do
    it "returns keys whose answers have substance (>10 chars), preserving the completeness heuristic" do
      daily_response = user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.current,
        answers: { "code_review" => "Found the N+1 in the loop", "pattern" => "short", "challenge" => "" }
      )

      expect(daily_response.answered_sections).to eq([ "code_review" ])
      expect(daily_response.completeness).to eq(33)
    end

    it "does not count whitespace-only answers, however long" do
      daily_response = user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.current,
        answers: { "code_review" => " " * 20 }
      )

      expect(daily_response.answered_sections).to be_empty
    end
  end

  describe "#self_rating_favorable? and #self_rating_unfavorable?" do
    it "treats right_level and too_easy as favorable, too_hard as unfavorable, nil as neither" do
      favorable_right_level = user.daily_responses.create!(daily_exercise: exercise, date: Date.current, answers: {}, rating: :right_level)
      favorable_too_easy    = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 1, answers: {}, rating: :too_easy)
      unfavorable           = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 2, answers: {}, rating: :too_hard)
      unrated               = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 3, answers: {})

      expect(favorable_right_level.self_rating_favorable?).to be(true)
      expect(favorable_too_easy.self_rating_favorable?).to be(true)
      expect(unfavorable.self_rating_favorable?).to be(false)
      expect(unrated.self_rating_favorable?).to be(false)

      expect(unfavorable.self_rating_unfavorable?).to be(true)
      expect(favorable_right_level.self_rating_unfavorable?).to be(false)
      expect(unrated.self_rating_unfavorable?).to be(false)
    end
  end

  describe "#ai_rating_for, #ai_rating_favorable?, and #ai_rating_unfavorable?" do
    it "reads the per-section rating out of ai_review, nil-safe when unreviewed or the section is missing" do
      reviewed = user.daily_responses.create!(
        daily_exercise: exercise, date: Date.current, answers: {},
        ai_review: { "code_review" => { "rating" => "developing" }, "pattern" => { "rating" => "strong" } }
      )
      unreviewed = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 1, answers: {})

      expect(reviewed.ai_rating_for("code_review")).to eq("developing")
      expect(reviewed.ai_rating_favorable?("code_review")).to be(false)
      expect(reviewed.ai_rating_unfavorable?("code_review")).to be(true)

      expect(reviewed.ai_rating_for("pattern")).to eq("strong")
      expect(reviewed.ai_rating_favorable?("pattern")).to be(true)
      expect(reviewed.ai_rating_unfavorable?("pattern")).to be(false)

      expect(reviewed.ai_rating_for("challenge")).to be_nil
      expect(reviewed.ai_rating_favorable?("challenge")).to be(false)
      expect(reviewed.ai_rating_unfavorable?("challenge")).to be(false)

      expect(unreviewed.ai_rating_for("code_review")).to be_nil
      expect(unreviewed.ai_rating_favorable?("code_review")).to be(false)
      expect(unreviewed.ai_rating_unfavorable?("code_review")).to be(false)
    end
  end

  describe "#self_rating_label" do
    it "matches the feedback form's copy and is nil when unrated" do
      right_level = user.daily_responses.create!(daily_exercise: exercise, date: Date.current, answers: {}, rating: :right_level)
      unrated     = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 1, answers: {})

      expect(right_level.self_rating_label).to eq("just right")
      expect(unrated.self_rating_label).to be_nil
    end
  end
end
