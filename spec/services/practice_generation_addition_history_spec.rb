require "rails_helper"

RSpec.describe "Practice addition schedule history" do
  include AuthHelpers
  include LiveSolveHelpers

  let(:user) { create_fake_provider_user }
  let(:service) { FakeService.new("fake-key") }

  def schedule(version)
    options = { context: {}, daily: DailyKinds::DEFAULT,
      preferences: KindPreferences.none, evidence: { pending: [], struggle: {}, initial_reviewed_sets: 0 },
      hosts: DayHosts.new("ruby_rails", mode: :application_code), rotation_history: [], due: [], drills: [] }
    version == 1 ? PracticeSchedule.plan(**options, count: 2, setting: nil).notes : PracticeSchedule.single_plan(**options).notes
  end

  def append(exercise, kind:)
    original_keys = exercise.active_section_keys
    addition = exercise.exercise_additions.create!(request_uuid: SecureRandom.uuid, kind: kind,
      draft_scope: exercise.draft_scope, date: exercise.date, status: "running", claimed_at: Time.current)
    context = PracticeGeneration.capture_addition(user, addition: addition, claim: addition.claimed_at)
    judged = service.generate_judged_exercise(user, language: exercise.language, schedule_context: context)
    result = PracticeGeneration.commit_append(user, addition: addition, claim: addition.claimed_at,
      context: context, judged: judged, drafted_by: service)

    expect(result.status).to eq(:saved)
    expect(exercise.reload.active_section_keys).to eq(original_keys + [ kind ])
    expect(addition.reload.status).to eq("succeeded")
  end

  [ 1, 3 ].each do |version|
    it "leaves an older format-#{version} schedule row unchanged when today's set has no note" do
      prior = user.daily_exercises.create!(date: Date.yesterday, generated_at: 1.day.ago,
        problem_set: { "code_review" => { "question" => "Earlier work" } },
        plan_notes: { "practice_schedule" => schedule(version), "learner_extraction" => { "attempts" => 1 } })
      before = prior.attributes.deep_dup
      exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
        problem_set: { "pattern" => { "question" => "Today's work" } })

      append(exercise, kind: "design_comparison")

      expect(prior.reload.attributes).to eq(before)
      note = exercise.reload.practice_schedule
      expect(note.fetch("version")).to eq(3)
      expect(note.fetch("selected_kinds")).to eq(%w[pattern])
      expect(note.fetch("assignments")).to eq({})
      expect(note.fetch("sequence")).to eq(before.dig("plan_notes", "practice_schedule", "sequence"))
      expect(note.dig("continuation", "kind_service", exercise.language, "design_comparison")).to eq(note.fetch("sequence"))
      expect(PracticeSchedule.context_for(user)).to eq(note)
    end
  end
end
