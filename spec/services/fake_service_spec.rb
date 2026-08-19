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

      # Derived from the registry rather than restated: this example's whole
      # claim is "every kind", and a hardcoded list quietly stops meaning that
      # the moment a kind is added.
      expect(problem_set.keys).to match_array(ExerciseSection.keys)
      problem_set.each_value do |section|
        expect(section["concept"]).to be_present
        expect(section["concept"]).not_to eq("other")
      end
    end

    # The behavioural half of the faithfulness check: the canned plan omits the
    # empty-input case, and the canned translation omits it too. A fixture that
    # "helpfully" added a guard would let the faithfulness specs pass while
    # proving nothing.
    it "returns a translation that preserves the gap its own critique names" do
      expect(described_class::PSEUDOCODE_CRITIQUE["gaps"].join).to match(/empty/i)
      expect(described_class::PSEUDOCODE_TRANSLATION).not_to match(/empty\?|nil\?|blank\?|\.any\?/)
    end

    it "resolves to the architecture third when persisted, since architecture has top precedence" do
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: problem_set,
                                        language: "ruby_rails", generated_at: Time.current)

      expect(exercise.third_key).to eq("architecture")
    end

    it "resolves to the plan_review fourth section when persisted, since plan_review has top precedence" do
      problem_set = described_class.new(user.api_key).generate_exercise(user, language: "ruby_rails")
      exercise = DailyExercise.create!(user: user, date: Date.current, problem_set: problem_set,
                                        language: "ruby_rails", generated_at: Time.current)

      expect(exercise.fourth_key).to eq("plan_review")
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

  describe "#review_sections" do
    it "returns ok: true for each requested section, independently gradable" do
      user_exercise = DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: described_class::EXERCISE_PROBLEM_SET
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: user_exercise, date: Date.current,
        answers: { "code_review" => "N+1 query", "pattern" => "Extract a service object", "architecture" => "Move it to a job" },
        submitted_at: Time.current
      )

      results = described_class.new(user.api_key).review_sections(user, user_exercise, response, sections: %w[code_review pattern architecture])

      expect(results.keys).to match_array(%w[code_review pattern architecture])
      results.each_value do |outcome|
        expect(outcome[:ok]).to be(true)
        expect(outcome[:review]["correct"]).to be_an(Array)
      end
    end

    it "raises a clear error when the section key can't be extracted from the prompt" do
      service = described_class.new(user.api_key)

      expect {
        service.send(:call, system: "You are a senior Rails engineer giving direct, specific feedback", prompt: "no section marker here")
      }.to raise_error(/could not extract the section key/)
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
