# spec/models/daily_exercise_spec.rb
require "rails_helper"

RSpec.describe DailyExercise, type: :model do
  let(:user) { User.create!(email: "exercise-owner@example.com", name: "Owner") }

  it "defaults language to ruby_rails" do
    exercise = DailyExercise.create!(user: user, date: Date.current,
                                     problem_set: { "code_review" => {} }, generated_at: Time.current)
    expect(exercise.language).to eq("ruby_rails")
  end

  it "rejects an unrecognized language" do
    exercise = DailyExercise.new(user: user, date: Date.current,
                                 problem_set: { "code_review" => {} }, generated_at: Time.current,
                                 language: "python")
    expect(exercise).not_to be_valid
    expect(exercise.errors[:language]).to be_present
  end

  it "rejects 'mixed' -- language must be a resolved, generatable language, never the meta-preference" do
    exercise = DailyExercise.new(user: user, date: Date.current,
                                 problem_set: { "code_review" => {} }, generated_at: Time.current,
                                 language: "mixed")
    expect(exercise).not_to be_valid
    expect(exercise.errors[:language]).to be_present
  end

  it "accepts ruby_rails and javascript" do
    expect(DailyExercise.new(user: user, date: Date.current, problem_set: { "code_review" => {} },
                             generated_at: Time.current, language: "ruby_rails")).to be_valid
    expect(DailyExercise.new(user: user, date: Date.current, problem_set: { "code_review" => {} },
                             generated_at: Time.current, language: "javascript")).to be_valid
  end

  describe "#architecture" do
    it "reads the architecture blob with indifferent access, nil when absent" do
      user = User.create!(email: "arch@example.com", name: "Arch")
      with_arch = DailyExercise.new(problem_set: { "architecture" => { "concept" => "service_boundaries" } })
      without    = DailyExercise.new(problem_set: { "challenge" => { "concept" => "n_plus_one" } })

      expect(with_arch.architecture[:concept]).to eq("service_boundaries")
      expect(without.architecture).to be_nil
    end
  end

  describe "#security_review" do
    it "reads the security_review blob with indifferent access, nil when absent" do
      with_sec = DailyExercise.new(problem_set: { "security_review" => { "concept" => "xss_prevention" } })
      without  = DailyExercise.new(problem_set: { "challenge" => { "concept" => "n_plus_one" } })

      expect(with_sec.security_review[:concept]).to eq("xss_prevention")
      expect(without.security_review).to be_nil
    end
  end

  describe "#third_key" do
    it "returns 'architecture' when the architecture key is present" do
      exercise = DailyExercise.new(problem_set: { "architecture" => {} })
      expect(exercise.third_key).to eq("architecture")
    end

    it "returns 'security_review' when present without architecture" do
      exercise = DailyExercise.new(problem_set: { "security_review" => {} })
      expect(exercise.third_key).to eq("security_review")
    end

    it "returns 'challenge' when neither architecture nor security_review is present" do
      exercise = DailyExercise.new(problem_set: { "challenge" => {} })
      expect(exercise.third_key).to eq("challenge")
    end

    it "skips a third key present with a null value, falling through to the next real section" do
      exercise = DailyExercise.new(problem_set: { "architecture" => nil, "challenge" => {} })
      expect(exercise.third_key).to eq("challenge")
    end
  end
end
