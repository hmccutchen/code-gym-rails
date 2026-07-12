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
end
