require "rails_helper"
require Rails.root.join("script/answer_position_balance")

RSpec.describe AnswerPositionBalance do
  let(:user) { User.create!(email: "balance@example.com", name: "Balance") }
  let(:out) { StringIO.new }

  def exercise_on(date, better)
    section = { "piece_a" => "a", "piece_b" => "b", "answer_key" => { "better" => better, "deciding_fact" => "SECRET" } }
    DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "q" }, "design_comparison" => section })
  end

  it "counts each position across stored exercises and prints totals only" do
    exercise_on(Date.current, "a")
    exercise_on(Date.current - 1, "b")
    exercise_on(Date.current - 2, "b")
    DailyExercise.create!(user: user, date: Date.current - 3, generated_at: Time.current,
                          problem_set: { "code_review" => { "question" => "q" } })

    expect { described_class.new(out: out).report }.not_to change { [ DailyExercise.count, ApiUsage.count ] }

    expect(out.string).to include("design comparisons with an answer key: 3",
                                  "better piece shown as A: 1 (33.3%)", "better piece shown as B: 2 (66.7%)",
                                  "no usable position: 0")
    expect(out.string).not_to include("SECRET", user.email)
  end
end
