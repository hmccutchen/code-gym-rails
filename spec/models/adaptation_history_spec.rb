require "rails_helper"

RSpec.describe "AdaptationHistory", type: :model do
  let(:user) { User.create!(email: "adaptation-history@example.com") }

  def response_on(date, grade: "strong", submitted: true, owner: user)
    exercise = DailyExercise.create!(user: owner, date: date, language: "ruby_rails", generated_at: Time.current,
                                     problem_set: { "code_review" => { "question" => "q" } })
    DailyResponse.create!(user: owner, daily_exercise: exercise, date: date, answers: { "code_review" => "x" },
                          submitted_at: (Time.current if submitted), ai_review: { "code_review" => { "rating" => grade } })
  end

  def materialized
    counts = Hash.new(0)
    subscriber = ->(_name, _start, _finish, _id, payload) { counts[payload[:class_name]] += payload[:record_count] }
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") { yield }
    end
    counts.slice("DailyResponse", "DailyExercise")
  end

  it "bounds eager materialization for small retained windows" do
    (AdaptationHistory::BATCH_SIZE + 1).times { |i| response_on(Date.current - i) }

    [ 5, 10, 60 ].each do |limit|
      counts = materialized do
        dates = AdaptationHistory.recent(user, limit: limit, &:date)
        expect(dates).to eq(limit.times.map { |i| Date.current - i })
      end
      expect(counts.values_at("DailyResponse", "DailyExercise")).to all(be <= AdaptationHistory::BATCH_SIZE)
    end
  end

  it "does not materialize empty reviews while backfilling valid legacy grades" do
    oldest = response_on(Date.current - 3)
    response_on(Date.current - 2).update!(ai_review: {})
    response_on(Date.current - 1).update!(ai_review: nil)

    counts = materialized { expect(AdaptationHistory.recent(user, limit: 1, &:id)).to eq([ oldest.id ]) }

    expect(counts).to eq("DailyResponse" => 1, "DailyExercise" => 1)
  end

  it "refines strict candidates without losing ownership, submission or the exclusive date bound" do
    eligible = response_on(Date.current - 3)
    stamp = { "code_review" => { "rating" => "solid", "rubric" => ReviewedSectionResults::RUBRIC_VERSION } }
    eligible.update!(ai_review: stamp)
    response_on(Date.current - 2)
    response_on(Date.current - 1, submitted: false).update!(ai_review: stamp)
    response_on(Date.current).update!(ai_review: stamp)
    other = User.create!(email: "strict-other@example.com")
    response_on(eligible.date, owner: other).update!(ai_review: stamp)

    counts = materialized do
      expect(AdaptationHistory.recent(user, limit: 1, before: Date.current, require_rubric: true, &:id)).to eq([ eligible.id ])
    end
    expect(counts).to eq("DailyResponse" => 1, "DailyExercise" => 1)
  end

  it "preserves basic and strict results through coarse filters for malformed and partial reviews" do
    stamp = ReviewedSectionResults::RUBRIC_VERSION
    good = { "rating" => "solid", "rubric" => stamp }
    cases = {
      nil_review: nil, empty: {}, array: [], scalar: "review", number: 2, boolean: true,
      top_array: [ { "code_review" => good } ], missing_grade: { "code_review" => { "rubric" => stamp } },
      bad_grade: { "code_review" => good.merge("rating" => "excellent") },
      nested_scalar: { "code_review" => "solid" }, nested_array: { "code_review" => [ good ] },
      unstamped: { "code_review" => { "rating" => "solid" } },
      old_stamp: { "code_review" => good.merge("rubric" => stamp - 1) },
      string_stamp: { "code_review" => good.merge("rubric" => stamp.to_s) },
      float_stamp: { "code_review" => good.merge("rubric" => stamp.to_f) },
      array_stamp: { "code_review" => good.merge("rubric" => [ stamp ]) },
      valid: { "code_review" => good }, partial_pending: { "code_review" => good },
      partial_failed: { "code_review" => good, "pattern" => good.merge("rating" => "invalid") },
      skipped: { "code_review" => good }, draft: { "code_review" => good },
      inactive_stamp: { "code_review" => { "rating" => "solid" }, "pattern" => good },
      eased: { "code_review" => good }, no_rung: { "code_review" => good }, malformed_answers: { "code_review" => good }
    }
    labels = cases.each_with_index.to_h do |(label, review), index|
      response = response_on(Date.current - index, submitted: label != :draft)
      data = { "question" => "q", "pitched_at" => "senior" }
      data["eased"] = true if label == :eased
      data.delete("pitched_at") if label == :no_rung
      problem = { "code_review" => data }
      answers = { "code_review" => "x" }
      if %i[partial_pending partial_failed].include?(label)
        problem["pattern"] = data.dup
        answers["pattern"] = "y"
      end
      answers = {} if label == :skipped
      answers = [] if label == :malformed_answers
      response.daily_exercise.update!(problem_set: problem)
      response.update!(ai_review: review, answers: answers)
      [ response.id, label ]
    end
    candidates = user.daily_responses.submitted.preload(:daily_exercise).order(date: :desc, id: :desc)
    basic = candidates.select { |response| response.assessed_sections.any? }.map(&:id)
    strict = candidates.flat_map { |response| ReviewedSectionResults.for(response, require_rubric: true) }

    expect(AdaptationHistory.recent(user, limit: cases.size, &:id)).to eq(basic)
    expect(AdaptationHistory.recent(user, limit: cases.size, require_rubric: true) do |response|
      ReviewedSectionResults.for(response, require_rubric: true)
    end.flatten).to eq(strict)
    expect(basic.map { |id| labels.fetch(id) }).to include(:unstamped, :partial_pending, :partial_failed)
    expect(strict.map(&:date)).to eq(%i[float_stamp valid partial_pending partial_failed].map { |label| Date.current - cases.keys.index(label) })
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
    candidate_count = AdaptationHistory::BATCH_SIZE + 1
    oldest = response_on(Date.current - candidate_count)
    exercise_rows = candidate_count.times.map do |i|
      { user_id: user.id, date: Date.current - i, language: "ruby_rails", generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "q" } }, created_at: Time.current, updated_at: Time.current }
    end
    exercises = DailyExercise.insert_all!(exercise_rows, returning: %w[id date]).rows
    DailyResponse.insert_all!(exercises.map do |id, date|
      { user_id: user.id, daily_exercise_id: id, date: date, submitted_at: Time.current,
        answers: { "code_review" => "x" }, ai_review: { "code_review" => { "rating" => "invalid" } },
        created_at: Time.current, updated_at: Time.current }
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
