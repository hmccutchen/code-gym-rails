require "rails_helper"

RSpec.describe CompetencyGate::Evidence do
  include AuthHelpers
  let(:user) { create_user_with_key }
  let(:start) { Date.new(2026, 1, 1) }

  def row(n, keys: %w[pattern design_comparison], answered: keys, reviewed: answered, rubric: 1,
          rung: "junior", ratings: {}, notes: { "size" => 2 }, owner: user)
    exercise = DailyExercise.create!(user: owner, date: start + n, generated_at: Time.current, plan_notes: notes,
      problem_set: keys.index_with { { "question" => "q", "pitched_at" => rung } })
    DailyResponse.create!(user: owner, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: answered.index_with { "\nanswer" }, section_ratings: answered.index_with { "right_level" }.merge(ratings),
      ai_review: reviewed.index_with { { "rating" => "solid", "rubric" => rubric } })
  end

  def loaded(**options) = described_class.new(user, before: start + 200, **options).to_a

  it "separates basic completion and recovery ratings from strict proof and overload" do
    row(0, rubric: nil, ratings: { "pattern" => "too_hard" })
    event = loaded.sole
    expect(event.results).to eq([])
    expect(event.completion).to have_attributes(state: :complete, delivered: 2, answered: 2,
      ratings_known: true, too_hard: [ "pattern" ])
  end

  [ nil, 0, "1", [], 2 ].each do |stamp|
    it "does not smuggle a #{stamp.inspect} sibling into any strict window" do
      response = row(0, ratings: { "pattern" => "too_hard", "design_comparison" => "too_hard" })
      response.update!(ai_review: response.ai_review.deep_merge("pattern" => { "rubric" => stamp }))
      expect(loaded.sole.results.map(&:kind)).to eq([ "design_comparison" ])
      expect(loaded.sole.completion.too_hard).to match_array(%w[pattern design_comparison])
      expect(CompetencyGate.plan(loaded).evidence[:hard_tallies]).to eq("design_comparison" => 1)
    end
  end

  it "ignores pending and bug-only work while keeping real weekend core evidence" do
    row(0, reviewed: [])
    bug = row(1, keys: [ "code_review" ])
    bug.daily_exercise.update!(problem_set: { "code_review" => { "purpose" => "Find the trap", "pitched_at" => "junior" } })
    row(2)
    expect(loaded.map(&:date)).to eq([ start + 2 ])
  end

  it "keeps strict partials and waits only for answered core siblings for completion" do
    row(0, reviewed: [ "pattern" ])
    row(1, answered: [ "pattern" ])
    expect(loaded.map { |event| event.completion.state }).to eq(%i[unknown incomplete])
    expect(loaded.first.results.map(&:kind)).to eq([ "pattern" ])
  end

  it "validates assignment and server-rung context without consulting current targets" do
    row(0, notes: { "size" => "3", "kind_rungs" => { "pattern" => "senior", "alien" => "junior", "challenge" => [] } })
    event = loaded.sole
    expect(event.completion.assigned).to be_nil
    expect(event.rungs).to eq("pattern" => "senior")
    user.update!(section_kind_levels: { "pattern" => "principal_engineer" })
    expect(loaded.sole).to eq(event)
  end

  it "honors ownership and the exclusive bound for both projections" do
    row(0, rubric: nil)
    row(1)
    row(2, owner: create_user_with_key(email: "other@example.com"))
    expect(described_class.new(user, before: start + 1).map(&:date)).to eq([ start ])
    expect(CompetencyGate.for(user, before: start + 1)).to eq(CompetencyGate.plan(described_class.new(user, before: start + 1)))
  end

  it "replays past sixty days with bounded preloading and no global rubric prefilter" do
    5.times { |n| row(n) }
    (5..70).each { |n| row(n, rubric: nil) }
    counts = Hash.new(0)
    sql = []
    callback = ->(*, payload) { counts[payload[:class_name]] += payload[:record_count] }
    query = ->(*, payload) { sql << payload[:sql] if payload[:sql].match?(/SELECT.*"daily_(responses|exercises)"/) }
    events = nil
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
        ActiveSupport::Notifications.subscribed(query, "sql.active_record") { events = loaded(batch_size: 10) }
      end
    end
    expect(events.size).to eq(71)
    expect(sql.size).to eq(16)
    expect(counts.slice("DailyResponse", "DailyExercise")).to eq("DailyResponse" => 71, "DailyExercise" => 71)
    expect(CompetencyGate.plan(events).count).to eq(3)
  end

  it "replays a late review at its original date rather than appending another day" do
    4.times { |n| row(n) }
    response = row(4, reviewed: [ "pattern" ])
    partial = CompetencyGate.plan(loaded)
    response.update!(ai_review: response.ai_review.merge("design_comparison" => { "rating" => "solid", "rubric" => 1 }))
    final = CompetencyGate.plan(loaded)
    expect(loaded.size).to eq(5)
    expect(final.evidence[:kinds]["design_comparison"][:successes]).to eq(5)
    expect(partial.evidence[:kinds]["design_comparison"][:successes]).to eq(4)
    expect(final).to eq(CompetencyGate.plan(loaded(batch_size: 2)))
  end

  it "keeps every adaptation output equal when bugs are added or interleaved" do
    twin = create_user_with_key(email: "twin@example.com")
    10.times do |n|
      keys = n < 5 ? %w[pattern design_comparison] : %w[pattern design_comparison plan_review]
      notes = { "size" => n < 5 ? 2 : 3 }
      row(n * 2, keys: keys, notes: notes)
      copy = row(n * 2, keys: keys, notes: notes, owner: twin)
      copy.daily_exercise.update!(problem_set: copy.daily_exercise.problem_set.merge(
        "code_review" => { "purpose" => "Find the trap", "pitched_at" => "junior" }))
      copy.update!(answers: copy.answers.merge("code_review" => (n % 4 == 2 ? "" : "answer")),
        section_ratings: copy.section_ratings.merge("code_review" => "too_hard"),
        ai_review: copy.ai_review.merge("code_review" => { "rating" => [ "strong", "developing", nil, nil ][n % 4], "rubric" => 1 }))
    end
    71.times do |n|
      bug = row(n < 10 ? n * 2 + 1 : 21 + n - 10, keys: [ "code_review" ], owner: twin)
      bug.daily_exercise.update!(problem_set: { "code_review" => { "purpose" => "Find the trap", "pitched_at" => "junior" } })
    end
    expect(CompetencyGate.for(twin)).to eq(CompetencyGate.for(user))
    expected = LevelSuggestion::Evidence.for(user)
    expect(LevelSuggestion::Evidence.for(twin)).to have_attributes(results: expected.results, newest_date: expected.newest_date)
    expect(twin.recent_performance).to eq(user.recent_performance)
    expect(DailyPlan.size_for(twin)).to eq(DailyPlan.size_for(user))
    original_day = user.daily_exercises.find_by!(date: start + 18)
    copy_day = twin.daily_exercises.find_by!(date: start + 18)
    expect(SizeForecast.for(twin, copy_day)).to eq(SizeForecast.for(user, original_day))
    expect(twin.recent_delivered_content).not_to eq(user.recent_delivered_content)
    core = twin.daily_responses.find_by!(date: start + 18)
    core.update!(ai_review: core.ai_review.deep_merge("pattern" => { "rating" => "developing" }))
    expect(twin.recent_performance).not_to eq(user.recent_performance)
    expect(CompetencyGate.for(twin)).not_to eq(CompetencyGate.for(user))
  end

  it "restores comfortable recovery from unstamped basic completion without adding strict ratings" do
    5.times { |n| row(n) }
    2.times { |n| row(n + 5, keys: %w[pattern design_comparison plan_review], answered: [ "pattern" ], notes: { "size" => 3 }) }
    row(7, rubric: nil, rung: nil)
    row(8, rubric: nil, rung: nil)
    plan = CompetencyGate.plan(loaded)
    expect(plan).to have_attributes(count: 3, safety_hold: false)
    expect(plan.evidence[:overload]).to eq([])
  end

  it "uses basic hard ratings to reset recovery without entering strict overload" do
    5.times { |n| row(n) }
    2.times { |n| row(n + 5, keys: %w[pattern design_comparison plan_review], answered: [ "pattern" ], notes: { "size" => 3 }) }
    row(7, rubric: nil)
    row(8, rubric: nil, ratings: { "pattern" => "too_hard", "design_comparison" => "too_hard" })
    row(9, rubric: nil)
    plan = CompetencyGate.plan(loaded)
    expect(plan).to have_attributes(count: 2, safety_hold: true)
    expect(plan.evidence[:overload]).to eq([])
    row(10, rubric: nil)
    expect(CompetencyGate.plan(loaded)).to have_attributes(count: 3, safety_hold: false)
  end

  it "bounds default-batch eager loading while replaying every candidate" do
    (described_class::BATCH_SIZE + 2).times { |n| row(n) }
    sizes = Hash.new { |hash, key| hash[key] = [] }
    callback = ->(*, payload) { sizes[payload[:class_name]] << payload[:record_count] }
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { expect(loaded.size).to eq(102) }
    end
    expect(sizes.slice("DailyResponse", "DailyExercise")).to eq("DailyResponse" => [ 100, 2 ], "DailyExercise" => [ 100, 2 ])
  end

  it "omits malformed rows but retains valid siblings and validates legacy assignment shapes" do
    [ 42, [], "bad" ].each_with_index do |value, n|
      response = row(n)
      response.daily_exercise.update_columns(plan_notes: value)
    end
    response = row(3)
    response.update_columns(ai_review: response.ai_review.merge("pattern" => [ "solid" ]))
    expect(loaded.map(&:date)).to eq([ start + 3 ])
    expect(loaded.sole.results.map(&:kind)).to eq([ "design_comparison" ])
  end
end
