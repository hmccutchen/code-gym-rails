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

  it "is refused by AiService.for outside a local environment" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

    expect { AiService.for(user) }.to raise_error(AiService::Error, /test-only fake provider/)
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

    it "raises a clear error when the third section key can't be extracted from the prompt" do
      service = described_class.new(user.api_key)

      expect {
        service.send(:call, system: "You are giving direct, specific feedback", prompt: "no keys line here")
      }.to raise_error(/could not extract the third section key/)
    end
  end

  describe "#generate_concept_reference" do
    it "returns every required CONCEPT_REFERENCE_FIELDS field non-blank" do
      reference = described_class.new(user.api_key).generate_concept_reference(user, "n_plus_one", "ruby_rails")

      AiService::CONCEPT_REFERENCE_FIELDS.each do |field|
        expect(reference[field].to_s.strip).to be_present
      end
    end
  end

  describe "#explain_differently" do
    it "returns non-blank plain prose" do
      exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails",
                                        generated_at: Time.current, problem_set: described_class::EXERCISE_PROBLEM_SET)
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                        answers: { "pattern" => "Extract a service object" })

      text = described_class.new(user.api_key).explain_differently(user, exercise, response, section: "pattern")

      expect(text).to be_present
    end
  end

  describe "#answer_follow_up" do
    it "returns non-blank plain prose" do
      exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails",
                                        generated_at: Time.current, problem_set: described_class::EXERCISE_PROBLEM_SET)
      response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                        answers: { "pattern" => "Extract a service object" })

      text = described_class.new(user.api_key).answer_follow_up(
        user, exercise, response, section: "pattern", question: "Why not just a bigger model?"
      )

      expect(text).to be_present
    end
  end
end
