require "rails_helper"

RSpec.describe "AdaptationHistory", type: :model do
  let(:user) { User.create!(email: "adaptation-history@example.com") }

  def response_on(date, grade: "strong", submitted: true, owner: user)
    exercise = DailyExercise.create!(user: owner, date: date, language: "ruby_rails", generated_at: Time.current,
                                     problem_set: { "code_review" => { "question" => "q" } })
    DailyResponse.create!(user: owner, daily_exercise: exercise, date: date, answers: { "code_review" => "x" },
                          submitted_at: (Time.current if submitted), ai_review: { "code_review" => { "rating" => grade } })
  end

  it "filters basic and consumer eligibility before limiting, with an exclusive date bound and user isolation" do
    oldest = response_on(Date.current - 80)
    newer = response_on(Date.current - 79)
    65.times { |i| response_on(Date.current - i, grade: nil) }
    response_on(Date.current - 66, grade: "developing")
    response_on(Date.current - 67, submitted: false)
    other = User.create!(email: "adaptation-other@example.com")
    response_on(Date.current - 68, owner: other)

    expect(AdaptationHistory.recent(user, limit: 2) { |r| r.date if r.ai_rating_for("code_review") == "strong" })
      .to eq([ newer.date, oldest.date ])
    expect(AdaptationHistory.recent(user, limit: 2, before: newer.date) { |r| r.date }).to eq([ oldest.date ])
  end

  it "crosses cursor batches with preloaded exercises and stops after qualifying projections" do
    oldest = response_on(Date.current - 1001)
    exercise_rows = 1001.times.map do |i|
      { user_id: user.id, date: Date.current - i, language: "ruby_rails", generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "q" } }, created_at: Time.current, updated_at: Time.current }
    end
    exercises = DailyExercise.insert_all!(exercise_rows, returning: %w[id date]).rows
    DailyResponse.insert_all!(exercises.map do |id, date|
      { user_id: user.id, daily_exercise_id: id, date: date, submitted_at: Time.current,
        answers: { "code_review" => "x" }, ai_review: {}, created_at: Time.current, updated_at: Time.current }
    end)
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].start_with?("SELECT") }
    results = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      AdaptationHistory.recent(user, limit: 1) do |r|
        expect(r.association(:daily_exercise)).to be_loaded
        r.id
      end
    end
    expect(results).to eq([ oldest.id ])
    expect(queries.grep(/FROM "daily_responses"/).size).to eq(2)
    expect(queries.grep(/FROM "daily_exercises"/).size).to eq(2)
  end
end
