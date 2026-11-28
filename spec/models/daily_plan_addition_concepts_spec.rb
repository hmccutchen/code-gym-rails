require "rails_helper"

RSpec.describe DailyPlan, "concepts for an additional exercise" do
  let(:user) { User.create!(email: "addition-concepts@example.com", language: "ruby_rails") }

  around { |example| travel_to(Time.zone.local(2026, 11, 26, 12)) { example.run } }

  it "keeps a due concept eligible for the requested host even when today's first exercise contains it" do
    concept = "memoization"
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "concept" => concept } }, section_order: %w[code_review])
    due = user.concept_masteries.create!(concept: concept, language: "ruby_rails", tier: :standard,
      mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.yesterday)
    context = PracticeGeneration.capture(user, date: Date.current).merge(requested_kind: "pattern", existing_concepts: [ concept ])

    plan = described_class.for(user, language: "ruby_rails", schedule_context: context)

    expect(plan.kinds).to eq([ ExerciseSection::Pattern ])
    expect(plan.assignments.fetch("pattern")).to include(concept: concept, reason: "retention")
    expect(plan.due_checks).to eq([ due ])
    expect(due.reload.next_retention_check_on).to eq(Date.yesterday)
  end
end
