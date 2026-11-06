require "rails_helper"

RSpec.describe PracticeGeneration do
  include AuthHelpers

  let(:user) { create_fake_provider_user }
  let(:service) { FakeService.new("fake-key") }

  def judged(context)
    AiService::JudgedSet.new(problem_set: { "pattern" => { "concept" => "memoization" } },
      dropped_sections: [], outcomes: {}, schedule_context: context,
      plan_notes: { "daily_kinds" => DailyKinds::DEFAULT.map(&:key) })
  end

  def active_judged(context)
    selection = PracticeSchedule.plan(context: context[:note], count: DailyKinds::COUNT, setting: nil, daily: DailyKinds::DEFAULT,
      preferences: KindPreferences.none, evidence: context[:evidence], hosts: DayHosts.new("ruby_rails", mode: :application_code),
      rotation_history: [], due: [], drills: [], replacing: context[:replacing_id].present?)
    judged(context).with(problem_set: selection.kinds.to_h { |kind| [ kind.key, { "question" => "A generated task" } ] },
      plan_notes: { "daily_kinds" => DailyKinds::DEFAULT.map(&:key), "practice_schedule" => selection.notes })
  end

  it "does not spend a turn while capturing and rejects a different-date stale completion" do
    first = described_class.capture(user, date: Date.current)
    second = described_class.capture(user, date: Date.current + 1)
    expect(user.daily_exercises.count).to eq(0)
    expect(described_class.commit_new(user, context: first, judged: judged(first), language: "ruby_rails", drafted_by: service).status).to eq(:saved)
    expect(described_class.commit_new(user, context: second, judged: judged(second), language: "ruby_rails", drafted_by: service).status).to eq(:superseded)
    expect(user.daily_exercises.count).to eq(1)
  end

  it "returns the winner on same-date duplicate completion without another insert" do
    context = described_class.capture(user, date: Date.current)
    2.times.map do |index|
      result = described_class.commit_new(user, context: context, judged: judged(context), language: "ruby_rails", drafted_by: service)
      expect(result.status).to eq(index.zero? ? :saved : :duplicate)
    end
    expect(user.daily_exercises.count).to eq(1)
  end

  it "rejects count and baseline changes without overwriting them or buying another call" do
    context = described_class.capture(user, date: Date.current)
    user.update!(daily_section_count: 2, skill_level: "senior")
    expect(described_class.commit_new(user, context: context, judged: judged(context), language: "ruby_rails", drafted_by: service).status).to eq(:superseded)
    expect(user.reload).to have_attributes(daily_section_count: 2, skill_level: "senior")
    expect(user.daily_exercises.count).to eq(0)
  end

  it "checks the original regeneration claim under user, exercise and response locks" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, problem_set: {})
    claim = exercise.claim_regenerating!
    context = described_class.capture(user, date: exercise.date, replacing: exercise)
    exercise.update!(regenerating_since: claim + 1.second)
    result = described_class.commit_replacement(user, exercise: exercise, claim: claim, context: context,
      judged: judged(context), drafted_by: service)
    expect(result.status).to eq(:superseded)
    expect(exercise.reload.regenerating_since).to eq(claim + 1.second)
  end

  [
    { daily_section_kinds: %w[architecture pattern] },
    { section_kind_levels: { "code_review" => "senior" } },
    { section_kind_levels: { "code_review" => "junior" }, locked_section_kinds: %w[code_review] },
    { section_kind_preferences_version: 1 }
  ].each do |change|
    it "discards an enrolled in-flight set after #{change.keys.join('/')} changes" do
      stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
      context = described_class.capture(user, date: Date.current)
      result = active_judged(context)
      user.update!(change)
      expect(described_class.commit_new(user, context: context, judged: result, language: "ruby_rails", drafted_by: service).status).to eq(:superseded)
      expect(user.daily_exercises).to be_empty
    end
  end

  it "allows a review arriving during generation without clearing its new request on delivery" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
    old = user.daily_exercises.create!(date: Date.yesterday, generated_at: Time.current, problem_set: { "pattern" => {} })
    context = described_class.capture(user, date: Date.current)
    response = user.daily_responses.create!(date: old.date, daily_exercise: old, submitted_at: Time.current,
      answers: { "pattern" => "An answered section" }, ai_review: { "pattern" => { "rating" => "developing" } })
    request = { "pattern" => { "mode" => "simplified", "source_response_id" => response.id, "requested_at" => Time.current.utc.iso8601(6) } }
    row = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", practice_requests: request)
    result = described_class.commit_new(user, context: context, judged: active_judged(context), language: "ruby_rails", drafted_by: service)
    expect(result.status).to eq(:saved)
    expect(row.reload.practice_requests).to eq(request)
  end

  it "keeps an older set's continuation when Start over returns after a newer set" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
    original_context = described_class.capture(user, date: Date.yesterday)
    original = described_class.commit_new(user, context: original_context, judged: active_judged(original_context),
      language: "ruby_rails", drafted_by: service).exercise
    note = original.practice_schedule
    claim = original.claim_regenerating!
    replacing = described_class.capture(user, date: original.date, replacing: original)
    next_context = described_class.capture(user, date: Date.current)
    newest = described_class.commit_new(user, context: next_context, judged: active_judged(next_context),
      language: "ruby_rails", drafted_by: service).exercise
    result = described_class.commit_replacement(user, exercise: original, claim: claim, context: replacing,
      judged: active_judged(replacing), drafted_by: service)
    expect(result.status).to eq(:saved)
    expect(original.reload.practice_schedule["continuation"]).to eq(note["continuation"])
    expect(PracticeSchedule.context_for(user)).to eq(newest.practice_schedule)
    expect(newest.practice_schedule["sequence"]).to eq(note["sequence"] + 1)
  end

  it "leaves a regenerated legacy row without a synthetic schedule turn" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
    legacy = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, problem_set: {})
    claim = legacy.claim_regenerating!
    context = described_class.capture(user, date: legacy.date, replacing: legacy)
    result = described_class.commit_replacement(user, exercise: legacy, claim: claim, context: context,
      judged: active_judged(context), drafted_by: service)
    expect(result.status).to eq(:saved)
    expect(legacy.reload.practice_schedule).to eq({})
  end
end
