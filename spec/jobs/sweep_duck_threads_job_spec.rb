require "rails_helper"
require "fugit"

RSpec.describe SweepDuckThreadsJob do
  include AuthHelpers

  let(:user) { create_user_with_key }

  def thread_on(date)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { "code_review" => { "question" => "Find the bug" } })
    DuckThread.append!(exercise, "code_review", message: "stuck", answer: "What runs first?",
                       expected_version: 0, expected_scope: exercise.draft_scope)
    exercise
  end

  it "deletes threads past the retention window and keeps the rest" do
    expired = thread_on(Date.current - DuckThread::KEPT_FOR - 1.day)
    kept    = thread_on(Date.current - 30.days)

    described_class.perform_now

    expect(DuckThread.pluck(:daily_exercise_id)).to eq([ kept.id ])
    expect(DailyExercise.exists?(expired.id)).to be(true)
  end

  it "runs daily in production" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "sweep_duck_threads")

    expect(schedule).to include("class" => described_class.name)
    expect(Fugit.parse_cron(schedule["schedule"]).rough_frequency).to eq(1.day.to_i)
  end
end
