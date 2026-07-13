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
end
