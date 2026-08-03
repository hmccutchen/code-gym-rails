require "rails_helper"

RSpec.describe FakeService do
  let(:user) do
    User.create!(email: "fake-svc@example.com", name: "Fake", provider: "fake", api_key: "fake-test-key")
  end

  it "is a valid provider value on User" do
    expect(user).to be_valid
  end

  it "is what AiService.for returns for a fake-provider user" do
    expect(AiService.for(user)).to be_a(FakeService)
  end

  describe "#generate_exercise" do
    it "returns a problem set covering every ExerciseSection kind with valid, non-'other' concepts" do
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")

      expect(problem_set.keys).to match_array(
        %w[code_review pattern challenge architecture security_review parsons_problem]
      )
      problem_set.each_value do |section|
        expect(section["concept"]).to be_present
        expect(section["concept"]).not_to eq("other")
      end
    end

    it "resolves to the architecture third when persisted, since architecture has top precedence" do
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: problem_set,
                                        language: "ruby_rails", generated_at: Time.current)

      expect(exercise.third_key).to eq("architecture")
    end

    it "logs API usage with zero cost" do
      expect {
        described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      }.to change(ApiUsage, :count).by(1)

      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(0)
      expect(usage.tokens_out).to eq(0)
    end
  end

  describe "#review_response" do
    it "returns a review keyed to the exercise's actual third_key" do
      user_exercise = DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: described_class::EXERCISE_PROBLEM_SET
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: user_exercise, date: Date.current,
        answers: { "code_review" => "N+1 query", "pattern" => "Extract a service object", "architecture" => "Move it to a job" }
      )

      review = described_class.new(user.api_key).review_response(user, user_exercise, response)

      expect(review.keys).to match_array(%w[code_review pattern architecture])
      expect(review["architecture"]["rating"]).to be_present
      expect(review["code_review"]["correct"]).to be_an(Array)
    end
  end
end
