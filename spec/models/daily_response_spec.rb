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
end
