require "rails_helper"

RSpec.describe DailyPlan, "one initial exercise" do
  let(:user) { User.create!(email: "single-plan@example.com", language: "ruby_rails") }

  it "plans one exercise for every historical count without replaying capacity" do
    expect(CompetencyGate).not_to receive(:for)
    expect(CoverageException).not_to receive(:for)

    [ nil, *User::DAILY_SECTION_COUNTS ].each do |count|
      user.update!(daily_section_count: count)
      plan = described_class.for(user, language: "ruby_rails")

      expect(plan.kinds.size).to eq(1)
      expect(plan.size).to have_attributes(count: 1, reason: :single)
      expect(plan.coverage).to be_nil
      expect(plan.shared_concept).to be_nil
      expect(user.reload.daily_section_count).to eq(count)
    end
  end

  it "leaves a due concept available when the selected kind cannot host it" do
    due = user.concept_masteries.create!(concept: "service_boundaries", language: "architecture",
      tier: :standard, mastered_at: 1.month.ago, retention_interval_days: 7,
      next_retention_check_on: Date.current - 10)
    allow(PracticeSchedule).to receive(:single_turn).and_wrap_original do |original, **options|
      original.call(**options.merge(daily: [ ExerciseSection::CodeReview ],
        preferences: KindPreferences.new(weights: {}, excluded: ExerciseSection.keys - [ "code_review" ])))
    end

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.kinds).to eq([ ExerciseSection::CodeReview ])
    expect(plan.due_checks + plan.fourth_due_checks).to be_empty
    expect(plan.waiting_checks).to include(include(concept: due.concept, bucket: due.language, reason: :no_host))
    expect(due.reload.next_retention_check_on).to eq(Date.current - 10)
  end

  it "uses the protected schedule only for an active captured context" do
    context = { active: true, date: Date.current, note: {}, replacing_id: nil,
      evidence: { pending: [], struggle: {}, initial_reviewed_sets: 0 } }

    active = described_class.for(user, language: "ruby_rails", schedule_context: context)
    inactive = described_class.for(user, language: "ruby_rails", schedule_context: context.merge(active: false))

    expect(active.practice_schedule).to include("version" => 2, "selected_kinds" => active.kinds.map(&:key))
    expect(inactive.kinds.size).to eq(1)
    expect(inactive.practice_schedule).to be_nil
    expect(inactive.assignments).to be_empty
  end

  it "considers ordinary reinforcement before choosing an equally served host" do
    allow(user).to receive(:concepts_needing_reinforcement).and_return([
      { concept: "service_boundaries", bucket: "architecture", tier: "reduced" }
    ])

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.kinds).to eq([ ExerciseSection::Architecture ])
    expect(plan.reinforcement).to include(include(concept: "service_boundaries", bucket: "architecture"))
  end

  it "does not forecast adaptive workload growth from the retired count policy" do
    exercise = DailyExercise.new(date: Date.current, plan_notes: { "size" => 4, "size_reason" => "gate" },
      problem_set: { "code_review" => {}, "design_comparison" => {} })

    expect(SizeForecast.for(user, exercise)).to be_nil
    expect(described_class.size_for(user).reduction?).to be(false)
    expect(described_class.size_for(user).brake?).to be(false)
  end

  context "when the regular pair includes an unselected weekend bug hunt" do
    let(:trap) { BugHuntGotchas.find("rb_memo_falsy") }

    around { |example| travel_to(Time.zone.local(2026, 11, 7, 9)) { example.run } }

    before do
      pin_code_review_mode(:bug_hunt)
      allow(BugHuntGotchas).to receive(:pick).and_return(trap)
    end

    def weekend_plan(active: true)
      context = PracticeGeneration.capture(user, date: Date.current).merge(active: active)
      described_class.for(user, language: "ruby_rails", schedule_context: context)
    end

    it "selects a hostable Pattern retry ahead of equally served regular kinds" do
      user.concept_masteries.create!(concept: trap.concept, language: "ruby_rails", tier: :standard,
        practice_requests: { "pattern" => { "mode" => "normal_retry", "source_response_id" => 17,
          "requested_at" => "2026-11-06T12:00:00.123456Z" } })

      plan = weekend_plan

      expect(plan.kinds).to eq([ ExerciseSection::Pattern ])
      expect(plan.code_review_gotcha).to be_nil
      expect(plan.assignments.fetch("pattern")).to include(concept: trap.concept, mode: "normal_retry")
    end

    it "selects an eligible retention host without excluding the unselected trap" do
      user.update!(daily_section_kinds: %w[code_review architecture])
      due = user.concept_masteries.create!(concept: trap.concept, language: "ruby_rails", tier: :standard,
        mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.yesterday)

      plan = weekend_plan

      expect(plan.code_review_gotcha).to be_nil
      expect(plan.due_checks).to eq([ due ])
      expect(plan.assignments.values).to include(include(concept: trap.concept, reason: "retention"))
      expect(due.reload.next_retention_check_on).to eq(Date.yesterday)
    end

    it "selects an eligible drill host without excluding the unselected trap" do
      user.update!(daily_section_kinds: %w[code_review architecture])
      mastery = user.concept_masteries.create!(concept: trap.concept, language: "ruby_rails", tier: :standard,
        drilled_at: Time.current)

      plan = weekend_plan

      expect(plan.code_review_gotcha).to be_nil
      expect(plan.assignments.values).to include(include(concept: trap.concept, reason: "drill"))
      expect(mastery.reload.drilled_at).to be_present
    end

    [ false, true ].each do |active|
      it "retains ordinary reinforcement priority with protected scheduling #{active ? 'active' : 'inactive'}" do
        user.update!(daily_section_kinds: %w[code_review architecture])
        exercise = user.daily_exercises.create!(date: Date.yesterday, generated_at: 1.day.ago, language: "ruby_rails",
          section_order: [ "code_review" ], problem_set: { "code_review" => { "concept" => trap.concept } })
        user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: 1.day.ago,
          answers: { "code_review" => "The cached false value needs to be retained." },
          section_ratings: { "code_review" => "too_hard" }, concept_tags: { "code_review" => trap.concept },
          ai_review: { "code_review" => { "rating" => "developing" } })

        plan = weekend_plan(active: active)

        expect(plan.code_review_gotcha).to be_nil
        expect(plan.reinforcement).to include(include(concept: trap.concept, bucket: "ruby_rails"))
      end
    end
  end
end
