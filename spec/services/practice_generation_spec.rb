require "rails_helper"

RSpec.describe PracticeGeneration do
  include AuthHelpers
  include LiveSolveHelpers

  let(:user) { create_fake_provider_user }
  let(:service) { FakeService.new("fake-key") }

  it "enrolls through real default generation and continues note-only enrollment after initiation is disabled" do
    pin_code_review_mode(:application_code)
    travel_to(Time.utc(2026, 11, 2, 12)) do
      expect(user.daily_exercises).to be_empty
      expect(user.daily_responses).to be_empty
      expect(user.concept_masteries).to be_empty
      context = described_class.capture(user, date: Date.current)
      expect(context[:active]).to be(true)
      result = service.generate_judged_exercise(user, language: "ruby_rails", schedule_context: context)
      first = described_class.commit_new(user, context: context, judged: result, language: "ruby_rails", drafted_by: service)
      expect(first.status).to eq(:saved)
      expect(first.exercise.active_section_keys).to eq(first.exercise.practice_schedule.fetch("selected_kinds"))
      expect(first.exercise.active_section_keys.size).to eq(1)
      expect(first.exercise.plan_notes).not_to have_key("coverage")
      expect(first.exercise.practice_schedule).to include("policy" => 2, "sequence" => 1)
      expect(user.daily_responses).to be_empty
      expect(user.concept_masteries).to be_empty

      stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
      next_context = described_class.capture(user, date: Date.tomorrow)
      expect(next_context[:active]).to be(true)
      next_result = service.generate_judged_exercise(user, language: "ruby_rails", schedule_context: next_context)
      second = described_class.commit_new(user, context: next_context, judged: next_result, language: "ruby_rails", drafted_by: service)
      expect(second.status).to eq(:saved)
      expect(second.exercise.practice_schedule["sequence"]).to eq(2)
      expect(second.exercise.active_section_keys.size).to eq(1)
      expect(first.exercise.reload.practice_schedule["sequence"]).to eq(1)
      untouched = create_fake_provider_user
      inactive = described_class.capture(untouched, date: Date.current)
      expect(inactive[:active]).to be(false)
      expect(untouched.daily_exercises).to be_empty
    end
  end

  it "records the accepted single exercise as the active section manifest" do
    user.update!(daily_section_count: 1)
    context = described_class.capture(user, date: Date.current)
    judged = service.generate_judged_exercise(user, language: "ruby_rails", schedule_context: context)

    result = described_class.commit_new(user, context: context, judged: judged,
      language: "ruby_rails", drafted_by: service)

    expect(result.status).to eq(:saved)
    expect(result.exercise.reload.section_order).to eq(judged.problem_set.keys)
    expect(result.exercise.problem_set.size).to eq(1)
    expect(result.exercise.active_section_keys).to eq(judged.problem_set.keys)
  end

  it "replaces a historical set with the accepted single exercise manifest" do
    user.update!(daily_section_count: 1)
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "pattern" => { "question" => "The original exercise" } }, section_order: %w[pattern])
    claim = exercise.claim_regenerating!
    context = described_class.capture(user, date: exercise.date, replacing: exercise)
    judged = service.generate_judged_exercise(user, language: "ruby_rails", schedule_context: context)

    result = described_class.commit_replacement(user, exercise: exercise, claim: claim,
      context: context, judged: judged, drafted_by: service)

    expect(result.status).to eq(:saved)
    expect(exercise.reload.section_order).to eq(judged.problem_set.keys)
    expect(exercise.active_section_keys.size).to eq(1)
    expect(exercise.practice_schedule).to eq({})
  end

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

  def single_judged(context, selected: %w[pattern])
    judged(context).with(plan_notes: {
      "daily_kinds" => DailyKinds::DEFAULT.map(&:key),
      "practice_schedule" => {
        "version" => 2, "policy" => 2, "sequence" => 1, "initial_ready" => false,
        "regular_kinds" => DailyKinds::DEFAULT.map(&:key), "selected_kinds" => selected,
        "assignments" => {}, "continuation" => { "kind_service" => { "pattern" => 1 }, "service" => {} }
      }
    })
  end

  it "commits the single-slot note and its matching manifest together" do
    context = described_class.capture(user, date: Date.current)
    result = described_class.commit_new(user, context: context, judged: single_judged(context),
      language: "ruby_rails", drafted_by: service)

    expect(result.status).to eq(:saved)
    expect(result.exercise.reload.section_order).to eq(%w[pattern])
    expect(result.exercise.practice_schedule).to include("version" => 2, "selected_kinds" => %w[pattern])
  end

  [ {}, { "code_review" => {} }, { "pattern" => {}, "code_review" => {} } ].each do |content|
    it "rejects single-slot content #{content.keys.inspect} that differs from the selected kind" do
      context = described_class.capture(user, date: Date.current)
      result = single_judged(context).with(problem_set: content)

      expect do
        described_class.commit_new(user, context: context, judged: result,
          language: "ruby_rails", drafted_by: service)
      end.to raise_error(ArgumentError, "Generated sections do not match the selected exercise")
      expect(user.daily_exercises).to be_empty
    end
  end

  it "rejects a multi-section initial write even when the note supports a later appended session" do
    context = described_class.capture(user, date: Date.current)
    result = single_judged(context, selected: %w[pattern code_review])
      .with(problem_set: { "pattern" => {}, "code_review" => {} })

    expect do
      described_class.commit_new(user, context: context, judged: result,
        language: "ruby_rails", drafted_by: service)
    end.to raise_error(ArgumentError, "Generated sections do not match the selected exercise")
    expect(user.daily_exercises).to be_empty
  end

  [ false, true ].each do |change_after_capture|
    it "plans from fresh captured settings with a stale caller, later edit=#{change_after_capture}" do
      caller = User.find(user.id)
      fresh = User.find(user.id)
      fresh.update!(daily_section_count: 3, daily_section_kinds: %w[architecture pattern code_review],
        skill_level: "junior", section_kind_weights: { "challenge" => 2.0 }, excluded_section_kinds: %w[security_review],
        section_kind_levels: { "pattern" => "senior", "code_review" => "mid_level" }, locked_section_kinds: %w[pattern])
      captured_settings = fresh.reload.attributes.slice(*described_class::SETTINGS)
      expect(caller.daily_section_count).not_to eq(3)
      context = described_class.capture(caller, date: Date.current)
      expect(context[:settings]).to eq(captured_settings)
      fresh.update!(daily_section_count: 2, daily_section_kinds: %w[code_review design_comparison],
        skill_level: "senior", section_kind_levels: {}, locked_section_kinds: []) if change_after_capture
      saved_settings = fresh.reload.attributes.slice(*described_class::SETTINGS)
      inputs = []
      allow(GenerationPrompt).to receive(:new).and_wrap_original do |method, *args, **options|
        result = method.call(*args, **options)
        inputs << [ options, result.render ]
        result
      end
      result = service.generate_judged_exercise(caller, language: "ruby_rails", schedule_context: context)
      expect(result.schedule_context).to equal(context)
      expect(result.problem_set.keys.size).to eq(1)
      expect(result.plan_notes).to include("size" => 1)
      expect(result.plan_notes.fetch("practice_schedule").fetch("regular_kinds")).to eq(%w[architecture pattern])
      expect(result.problem_set.transform_values { |section| section["pitched_at"] })
        .to eq(context.fetch(:kind_rungs).slice(*result.problem_set.keys))
      expect(inputs).not_to be_empty
      inputs.each do |options, text|
        expect(options[:skill_level]).to eq("junior")
        expect(options[:difficulty].locked?(ExerciseSection::Pattern)).to be(true)
        expect(options[:kind_rungs]).to eq(context.fetch(:kind_rungs))
        result.problem_set.each_key do |key|
          expect(text).to include("Sections at #{context.fetch(:kind_rungs).fetch(key)}: #{key}")
        end
      end
      expect(user.reload.attributes.slice(*described_class::SETTINGS)).to eq(saved_settings)
      outcome = described_class.commit_new(caller, context: context, judged: result, language: "ruby_rails", drafted_by: service)
      expect(outcome.status).to eq(change_after_capture ? :superseded : :saved)
      expect(user.daily_exercises.count).to eq(change_after_capture ? 0 : 1)
      expect(user.reload.attributes.slice(*described_class::SETTINGS)).to eq(saved_settings)
    end
  end

  it "carries validated readiness while asking for the newly configured regular pair" do
    context = described_class.capture(user, date: Date.yesterday)
    prior = active_judged(context)
    note = prior.plan_notes
    note["practice_schedule"]["initial_ready"] = true
    user.daily_exercises.create!(date: Date.yesterday, generated_at: Time.current, problem_set: prior.problem_set, plan_notes: note)
    user.update!(daily_section_kinds: %w[architecture pattern])
    expect(PracticeEvidence).to receive(:for).with(an_instance_of(User), before: Date.current,
      kinds: KindPreferences.offered_to(user).map(&:key), initial_ready: true).and_call_original
    carried = described_class.capture(user, date: Date.current)
    expect(carried[:evidence]).to include(initial_reviewed_sets: 2, struggle: {}, pending: [])
  end

  it "captures reviewed struggle for an optional kind that can become the single recommendation" do
    exercise = user.daily_exercises.create!(date: Date.yesterday, generated_at: Time.current,
      problem_set: { "pattern" => { "concept" => "memoization" } })
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: { "pattern" => "Cache the computed result." }, section_ratings: { "pattern" => "too_hard" },
      concept_tags: { "pattern" => "memoization" }, ai_review: { "pattern" => { "rating" => "developing" } })

    context = described_class.capture(user, date: Date.current)

    expect(context.fetch(:evidence).fetch(:struggle)).to include("pattern" => true)
  end

  %i[provider_failure all_rejected].each do |failure|
    it "keeps the committed single-slot service history when the next generation ends in #{failure}" do
      pin_code_review_mode(:application_code)
      context = described_class.capture(user, date: Date.yesterday)
      first_judged = service.generate_judged_exercise(user, language: "ruby_rails", schedule_context: context)
      previous = described_class.commit_new(user, context: context, judged: first_judged,
        language: "ruby_rails", drafted_by: service).exercise
      note = previous.practice_schedule
      expect(note.fetch("version")).to eq(2)
      expect(note.dig("continuation", "kind_service")).not_to be_empty
      if failure == :provider_failure
        allow_any_instance_of(FakeService).to receive(:generate_problem_set).and_raise(ProviderError, "Draft failed")
      else
        allow_any_instance_of(FakeService).to receive(:judge_section)
          .and_return(JudgeVerdict.new(status: :reject, principle: "underdetermined"))
      end

      GenerateDailyExercisesJob.perform_now(user_id: user.id)

      expect(user.daily_exercises.count).to eq(1)
      expect(user.daily_exercises.find_by(date: Date.current)).to be_nil
      expect(previous.reload.practice_schedule).to eq(note)
      expect(PracticeSchedule.context_for(user)).to eq(note)
      expect(user.reload.last_generation_error_date).to eq(Date.current)
    end
  end

  it "does not spend a turn while capturing and rejects a different-date stale completion" do
    first = described_class.capture(user, date: Date.current)
    second = described_class.capture(user, date: Date.current + 1)
    expect(user.daily_exercises.count).to eq(0)
    expect(described_class.commit_new(user, context: first, judged: active_judged(first), language: "ruby_rails", drafted_by: service).status).to eq(:saved)
    expect(described_class.commit_new(user, context: second, judged: active_judged(second), language: "ruby_rails", drafted_by: service).status).to eq(:superseded)
    expect(user.daily_exercises.count).to eq(1)
  end

  it "returns the winner on same-date duplicate completion without another insert" do
    context = described_class.capture(user, date: Date.current)
    2.times.map do |index|
      result = described_class.commit_new(user, context: context, judged: active_judged(context), language: "ruby_rails", drafted_by: service)
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
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Review the original code." } })
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
      context = described_class.capture(user, date: Date.current)
      result = active_judged(context)
      user.update!(change)
      expect(described_class.commit_new(user, context: context, judged: result, language: "ruby_rails", drafted_by: service).status).to eq(:superseded)
      expect(user.daily_exercises).to be_empty
    end
  end

  it "allows a review arriving during generation without clearing its new request on delivery" do
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
    legacy = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Review the original code." } })
    claim = legacy.claim_regenerating!
    context = described_class.capture(user, date: legacy.date, replacing: legacy)
    result = described_class.commit_replacement(user, exercise: legacy, claim: claim, context: context,
      judged: active_judged(context), drafted_by: service)
    expect(result.status).to eq(:saved)
    expect(legacy.reload.practice_schedule).to eq({})
  end

  %w[pattern code_review].each do |old_key|
    it "replaces the previous manifest when it listed #{old_key}" do
      exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
        problem_set: { old_key => {} }, section_order: [ old_key ])
      claim = exercise.claim_regenerating!
      context = described_class.capture(user, date: exercise.date, replacing: exercise)

      result = described_class.commit_replacement(user, exercise: exercise, claim: claim, context: context,
        judged: active_judged(context), drafted_by: service)

      expect(result.status).to eq(:saved)
      expect(exercise.reload.section_order).to eq(%w[code_review design_comparison])
      expect(exercise.active_section_keys).to eq(%w[code_review design_comparison])
    end
  end

  it "rolls back destruction of an active draft and its full continuation when replacement persistence fails" do
    first = described_class.capture(user, date: Date.current)
    exercise = described_class.commit_new(user, context: first, judged: active_judged(first),
      language: "ruby_rails", drafted_by: service).exercise
    exercise.update!(section_order: %w[code_review])
    draft = user.daily_responses.create!(date: exercise.date, daily_exercise: exercise, answers: { "code_review" => "Keep this draft" })
    JudgeSolve.record!(exercise, [ live_solve ])
    before_solves = JudgeSolve.where(daily_exercise_id: exercise.id).map(&:attributes)
    claim = exercise.claim_regenerating!
    context = described_class.capture(user, date: exercise.date, replacing: exercise)
    before_set, before_draft = exercise.reload.attributes, draft.attributes
    allow(exercise).to receive(:update!) do |**_attributes|
      expect(DailyResponse.exists?(draft.id)).to be(false)
      raise ActiveRecord::RecordNotSaved, "replacement storage refused"
    end
    expect do
      described_class.commit_replacement(user, exercise: exercise, claim: claim, context: context,
        judged: active_judged(context), drafted_by: service)
    end.to raise_error(ActiveRecord::RecordNotSaved)
    expect(exercise.reload.attributes).to eq(before_set)
    expect(draft.reload.attributes).to eq(before_draft)
    expect(JudgeSolve.where(daily_exercise_id: exercise.id).map(&:attributes)).to eq(before_solves)
  end
end
