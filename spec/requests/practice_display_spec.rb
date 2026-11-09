require "rails_helper"

RSpec.describe "Protected-practice display", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  def exercise_on(date, note: nil)
    user.daily_exercises.create!(date: date, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Review this", "snippet" => "value" },
        "design_comparison" => { "question" => "Compare", "option_a" => "A", "option_b" => "B" } },
      plan_notes: { "size" => 2 }.tap { |notes| notes["practice_schedule"] = note unless note.nil? })
  end

  it "shows active Setup, Learn and picker copy for an untouched account without an enrollment override" do
    exercise_on(Date.current)
    {
      setup_path => I18n.t("protected_practice.exercise_mix.intro"),
      learn_concept_path(bucket: "ruby_rails", concept: "memoization") => I18n.t("protected_practice.learn.drill.offer"),
      root_path => I18n.t("protected_practice.daily_kinds.outgoing", outgoing: "Code Review")
    }.each do |path, copy|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(copy)
      expect(response.body).not_to include(I18n.t("protected_practice.unavailable"))
    end
    expect(user.daily_responses).to be_empty
    expect(user.concept_masteries).to be_empty
    expect(user.daily_exercises.sole.plan_notes).not_to have_key("practice_schedule")
  end

  it "keeps Setup, dashboard and Learn available without either policy's promises on invalid historical receipts" do
    old = exercise_on(Date.yesterday)
    receipt = { "version" => 99, "secret" => "PRIVATE-GAP-ANSWER" }
    row = user.daily_responses.create!(daily_exercise: old, date: old.date, mastery_application: receipt)
    today = exercise_on(Date.current)
    warnings = []
    allow(Rails.logger).to receive(:warn) { |message| warnings << message }
    pages = [ setup_path, root_path, learn_concept_path(bucket: "ruby_rails", concept: "memoization") ]
    pages.each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("protected_practice.unavailable"))
      expect(response.body).not_to include(I18n.t("learn.drill.offer"), I18n.t("protected_practice.learn.drill.offer"),
        "PRIVATE-GAP-ANSWER", "weeks to cycle")
    end
    display_warnings = warnings.grep(/\[practice_display\]/)
    expect(display_warnings.size).to be_between(1, pages.size * (DailyKinds::COUNT + 1))
    expect(display_warnings).to all(eq("[practice_display] user_id=#{user.id} error=ArgumentError"))
    expect(row.reload.mastery_application).to eq(receipt)
    expect(today.reload.plan_notes).to eq("size" => 2)
  end

  it "renders an unavailable dashboard note and picker for malformed current schedule state without rewriting it" do
    note = { "version" => 42, "hidden" => "PRIVATE-NOTE" }
    today = exercise_on(Date.current, note: note)
    get root_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("protected_practice.unavailable"))
    expect(response.body).not_to include("PRIVATE-NOTE", I18n.t("protected_practice.dashboard.adjusted"))
    expect(today.reload.plan_notes["practice_schedule"]).to eq(note)
    expect { today.practice_schedule }.to raise_error(ArgumentError)
  end

  it "still refuses Learn's selected corrupt reservation suffix instead of inventing capacity" do
    row = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails",
      review_reconciliation: { "version" => 99 })
    expect { get learn_path }.to raise_error(ArgumentError)
    expect(row.reload.review_reconciliation).to eq("version" => 99)
  end

  it "shows only delivered variety and the approved generic adjustment, qualified for unchanged settings" do
    selected = PracticeSchedule.plan(context: nil, count: 2, setting: nil, daily: DailyKinds::DEFAULT,
      preferences: KindPreferences.none, evidence: { initial_reviewed_sets: 2, pending: [], struggle: {} },
      hosts: DayHosts.new("ruby_rails", mode: :application_code), rotation_history: [], due: [], drills: [])
    replacement = (selected.notes.fetch("selected_kinds") - selected.notes.fetch("regular_kinds")).sole
    today = exercise_on(Date.current, note: selected.notes)
    rungs = selected.kinds.to_h { |kind| [ kind.key, "junior" ] }
    adjustments = PracticeAdjustment.resolve(assignments: rungs.keys.index_with { { mode: "simplified" } },
      difficulty: KindDifficulty.none, rungs: rungs, reduced: {})
    data = ProblemSetIngest.call(FakeService::EXERCISE_PROBLEM_SET.deep_dup, language: "ruby_rails",
      expected_keys: selected.kinds.map(&:key), daily: DailyKinds::DEFAULT, pitched_at: rungs, assignments: adjustments).problem_set
    today.update!(problem_set: data)
    expect(today.active_section_keys).to match_array(selected.notes.fetch("selected_kinds"))
    expect(today.active_section_keys).to include(replacement)
    get root_path
    expect(response.body).to include("Practice adjusted from your reviewed feedback.",
      I18n.t("protected_practice.dashboard.variety", kind: I18n.t("sections.#{replacement}.name")))
    expect(response.body).not_to include("normal retry follows", "simpler reasoning")
    continuation = today.practice_schedule.fetch("continuation")
    today.update!(problem_set: today.problem_set.except(replacement), dropped_sections: [ replacement ])
    get root_path
    expect(response.body).not_to include("for variety")
    expect(today.reload.practice_schedule.fetch("continuation")).to eq(continuation)
  end
end
