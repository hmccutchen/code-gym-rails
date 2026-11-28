require "rails_helper"

RSpec.describe "Practice generation additions" do
  include AuthHelpers
  include LiveSolveHelpers

  let(:user) { create_fake_provider_user }
  let(:service) { FakeService.new("fake-key") }

  def initial
    context = PracticeGeneration.capture(user, date: Date.current)
    judged = service.generate_judged_exercise(user, language: "ruby_rails", schedule_context: context)
    PracticeGeneration.commit_new(user, context: context, judged: judged, language: "ruby_rails", drafted_by: service).exercise
  end

  def start_addition(exercise)
    kind = (KindPreferences.offered_to(user).map(&:key) - exercise.active_section_keys).first
    exercise.exercise_additions.create!(request_uuid: SecureRandom.uuid, kind: kind, draft_scope: exercise.draft_scope,
      date: Date.current, status: "running", claimed_at: Time.current)
  end

  it "appends exactly the requested kind without replacing draft state or advancing the initial schedule" do
    pin_code_review_mode(:application_code)
    exercise = initial
    original = exercise.attributes.deep_dup
    response = user.daily_responses.create!(daily_exercise: exercise, date: exercise.date,
      answers: { exercise.active_section_keys.first => "My answer" }, section_ratings: { exercise.active_section_keys.first => "right_level" })
    response_before = response.attributes.deep_dup
    addition = start_addition(exercise)
    context = PracticeGeneration.capture_addition(user, addition: addition, claim: addition.claimed_at)
    judged = service.generate_judged_exercise(user, language: exercise.language, schedule_context: context)
    expect(judged.problem_set.keys).to eq([ addition.kind ])

    result = PracticeGeneration.commit_append(user, addition: addition, claim: addition.claimed_at,
      context: context, judged: judged, drafted_by: service)

    expect(result.status).to eq(:saved)
    exercise.reload
    expect(exercise.problem_set.slice(*original.fetch("problem_set").keys)).to eq(original.fetch("problem_set"))
    expect(exercise.active_section_keys).to eq(original.fetch("section_order") + [ addition.kind ])
    expect(exercise.generated_at).to eq(original.fetch("generated_at"))
    expect(response.reload.attributes).to eq(response_before)
    expect(exercise.draft_scope).to eq(addition.draft_scope)
    expect(exercise.practice_schedule.except("continuation")).to eq(original.dig("plan_notes", "practice_schedule").except("continuation"))
    expect(exercise.plan_notes.fetch("additions")).to have_key(addition.kind)
    expect(addition.reload.status).to eq("succeeded")
    expect(PracticeGeneration.commit_append(user, addition: addition, claim: context.fetch(:addition_claim),
      context: context, judged: judged, drafted_by: service).status).to eq(:superseded)
  end

  it "rejects a changed provider identity without changing existing work" do
    exercise = initial
    original = exercise.problem_set.deep_dup
    addition = start_addition(exercise)
    context = PracticeGeneration.capture_addition(user, addition: addition, claim: addition.claimed_at)
    judged = service.generate_judged_exercise(user, language: exercise.language, schedule_context: context)
    user.update!(api_keys: { user.provider => "different-key" })

    expect(PracticeGeneration.commit_append(user, addition: addition, claim: addition.claimed_at,
      context: context, judged: judged, drafted_by: service).status).to eq(:superseded)
    expect(exercise.reload.problem_set).to eq(original)
  end
  {
    "submission" => ->(user, exercise) { user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current) },
    "changed settings" => ->(user, _exercise) { user.update!(skill_level: user.skill_level == "senior" ? "junior" : "senior") },
    "newer set" => ->(user, exercise) { user.daily_exercises.create!(date: exercise.date + 1, generated_at: Time.current, problem_set: { "pattern" => { "question" => "New" } }) },
    "changed scope" => ->(_user, exercise) { exercise.update!(generated_at: exercise.generated_at + 1.minute) }
  }.each do |reason, change|
    it "does not append after #{reason}" do
      exercise = initial
      addition = start_addition(exercise)
      context = PracticeGeneration.capture_addition(user, addition: addition, claim: addition.claimed_at)
      judged = service.generate_judged_exercise(user, language: exercise.language, schedule_context: context)
      change.call(user, exercise)
      before = exercise.reload.problem_set.deep_dup

      expect(PracticeGeneration.commit_append(user, addition: addition, claim: addition.claimed_at,
        context: context, judged: judged, drafted_by: service).status).to eq(:superseded)
      expect(exercise.reload.problem_set).to eq(before)
    end
  end

  it "appends to a historical note-free set without losing its hidden keys or layout" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "pattern" => { "question" => "Old prompt", "answer_key" => "Private key" } })
    addition = start_addition(exercise)
    context = PracticeGeneration.capture_addition(user, addition: addition, claim: addition.claimed_at)
    judged = service.generate_judged_exercise(user, language: exercise.language, schedule_context: context)

    expect(PracticeGeneration.commit_append(user, addition: addition, claim: addition.claimed_at,
      context: context, judged: judged, drafted_by: service).status).to eq(:saved)
    expect(exercise.reload.active_section_keys).to eq([ "pattern", addition.kind ])
    expect(exercise.problem_set.dig("pattern", "answer_key")).to eq("Private key")
  end

  [ nil, 1, 2 ].each do |version|
    it "preserves a two-section historical envelope with note version #{version.inspect}" do
      schedule = PracticeSchedule.plan(context: {}, count: 2, setting: nil, daily: DailyKinds::DEFAULT,
        preferences: KindPreferences.none, evidence: { pending: [], struggle: {}, initial_reviewed_sets: 0 },
        hosts: DayHosts.new("ruby_rails", mode: :application_code), rotation_history: [], due: [], drills: []).notes
      if version == 2
        schedule = schedule.except("phase", "omitted_kind").merge("version" => 2,
          "continuation" => { "kind_service" => {}, "service" => {} })
      end
      notes = { "daily_kinds" => DailyKinds::DEFAULT.map(&:key) }
      notes["practice_schedule"] = schedule if version
      exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, plan_notes: notes,
        problem_set: DailyKinds::DEFAULT.to_h { |kind| [ kind.key, { "question" => "Original #{kind.key}" } ] })
      original = exercise.problem_set.deep_dup
      addition = start_addition(exercise)
      context = PracticeGeneration.capture_addition(user, addition: addition, claim: addition.claimed_at)
      judged = service.generate_judged_exercise(user, language: exercise.language, schedule_context: context)

      expect(PracticeGeneration.commit_append(user, addition: addition, claim: addition.claimed_at,
        context: context, judged: judged, drafted_by: service).status).to eq(:saved)
      expect(exercise.reload.problem_set.slice(*original.keys)).to eq(original)
      expect(exercise.active_section_keys).to eq(original.keys + [ addition.kind ])
      expect(exercise.practice_schedule.fetch("selected_kinds")).to eq(original.keys)
      expect(exercise.practice_schedule.fetch("assignments")).to eq(schedule.fetch("assignments")) if version
      expect(exercise.practice_schedule.fetch("sequence")).to eq(1)
    end
  end

  it "keeps an existing Bug Hunt trap excluded from an appended planning host" do
    trap = BugHuntGotchas.find("rb_memo_falsy")
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Find the issue", "concept" => trap.concept } },
      plan_notes: { "bug_hunt" => trap.id })
    addition = exercise.exercise_additions.create!(request_uuid: SecureRandom.uuid, kind: "pattern", draft_scope: exercise.draft_scope,
      date: exercise.date, status: "running", claimed_at: Time.current)
    context = PracticeGeneration.capture_addition(user, addition: addition, claim: addition.claimed_at)
    plan = DailyPlan.for(user, language: exercise.language, schedule_context: context)

    expect(plan.code_review_gotcha).to eq(trap)
    expect(ConceptVocabulary.selectable_for_section("pattern", exercise.language, gotcha: plan.code_review_gotcha)).not_to include(trap.concept)
  end

  it "chooses a new Bug Hunt trap outside concepts already present in the set" do
    pin_code_review_mode(:bug_hunt)
    concept = BugHuntGotchas.for_language("ruby_rails").first.concept
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "pattern" => { "question" => "Explain", "concept" => concept } })
    addition = exercise.exercise_additions.create!(request_uuid: SecureRandom.uuid, kind: "code_review", draft_scope: exercise.draft_scope,
      date: exercise.date, status: "running", claimed_at: Time.current)
    context = PracticeGeneration.capture_addition(user, addition: addition, claim: addition.claimed_at)
    plan = DailyPlan.for(user, language: exercise.language, schedule_context: context)

    expect(plan.code_review_gotcha).to be_present
    expect(plan.code_review_gotcha.concept).not_to eq(concept)
  end
end
