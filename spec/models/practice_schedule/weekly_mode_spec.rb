require "rails_helper"

RSpec.describe "Persisted weekly practice opportunities", type: :model do
  let(:start) { Date.new(2026, 11, 7) }
  let(:excluded) { %w[architecture security_review parsons_problem] }

  before do
    allow(WeightedRoll).to receive(:pick).with(DailyPlan::WEEKEND_CODE_REVIEW_MODE_WEIGHTS).and_call_original
    first_tie = true
    allow(WeightedRoll).to receive(:pick).with(DailyKinds::DEFAULT.index_with { KindPreferences::DEFAULT_MULTIPLIER }).and_wrap_original do |original, weights|
      if first_tie
        first_tie = false
        ExerciseSection::CodeReview
      else
        original.call(weights)
      end
    end
  end

  %w[support normal_retry].each do |mode|
    it "serves #{mode} on a core Code Review despite an initial weekend alignment" do
      user = User.create!(email: "weekly-#{mode}@example.com", language: "ruby_rails", excluded_section_kinds: excluded)
      mastery = pending_request(user, mode: mode, language: "ruby_rails", concept: "service_objects", date: start - 8)
      pool = KindPreferences.offered_to(user)
      expect(pool.size).to eq(7)
      (pool - DailyKinds.for(user)).each_with_index do |kind, index|
        user.daily_exercises.create!(date: start - 5 + index, language: "ruby_rails", generated_at: (start - 5 + index).noon,
          section_order: [ kind.key ], problem_set: { kind.key => { "question" => "Earlier delivered exercise" } })
      end

      turns = committed_turns(user, count: pool.size * 10)

      expect(turns.first(2)).to include(a_hash_including(kind: "code_review", core: false))
      core = turns.each_index.select { |index| turns[index].values_at(:kind, :core) == [ "code_review", true ] }
      expect(core).not_to be_empty
      expect(core.first).to be < pool.size * 3
      expect(core.each_cons(2).map { |left, right| right - left }.max).to be <= pool.size * 2
      expect(turns.flat_map { |turn| turn[:assignments] }).to include(
        a_hash_including(kind: "code_review", concept: "service_objects", bucket: "ruby_rails", reason: mode))
      expect(mastery.reload.practice_requests.dig("code_review", "mode")).to eq(mode)
      expect_bounded_variety(turns, pool)
    end
  end

  it "keeps ordinary kinds and maintenance moving independently in both generated languages" do
    user = User.create!(email: "weekly-mixed@example.com", language: "mixed", excluded_section_kinds: excluded)
    pending_request(user, mode: "support", language: "ruby_rails", concept: "service_objects", date: start - 9)
    pending_request(user, mode: "normal_retry", language: "javascript", concept: "closures", date: start - 8)
    retention = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :standard,
      next_retention_check_on: start - 1, retention_interval_days: 7)
    drill = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", drilled_at: (start - 1).noon)
    pool = KindPreferences.offered_to(user)

    turns = committed_turns(user, count: pool.size * 20)

    turns.group_by { |turn| turn[:language] }.each do |language, language_turns|
      expect_bounded_variety(language_turns, pool)
      expect(language_turns.flat_map { |turn| turn[:assignments] }).to include(
        a_hash_including(kind: "code_review", bucket: language, reason: language == "ruby_rails" ? "support" : "normal_retry"))
    end
    expect(turns.flat_map { |turn| turn[:assignments] }).to include(
      a_hash_including(reason: "retention", concept: retention.concept), a_hash_including(reason: "drill", concept: drill.concept))
    expect(retention.reload.next_retention_check_on).to eq(start - 1)
    expect(drill.reload.drilled_at).to eq((start - 1).noon)
  end

  def pending_request(user, mode:, language:, concept:, date:)
    daily = DailyKinds.for(user)
    source = user.daily_exercises.create!(date: date, language: language, generated_at: date.noon,
      section_order: daily.map(&:key), problem_set: daily.to_h do |kind|
        [ kind.key, { "concept" => concept, "snippet" => "def call; work; end", "question" => "Review the implementation",
          "eased" => (mode == "normal_retry" && kind.key == "code_review") } ]
      end)
    response = user.daily_responses.create!(daily_exercise: source, date: date, submitted_at: date.noon,
      answers: { "code_review" => "Separate the orchestration into a service." },
      section_ratings: { "code_review" => mode == "support" ? "too_hard" : "right_level" },
      concept_tags: { "code_review" => concept }, ai_review: { "code_review" => { "rating" => "solid" } })
    expect(response.assessed_adaptation_sections).to include("code_review")
    user.concept_masteries.create!(concept: concept, language: language, practice_requests: {
      "code_review" => { "mode" => mode, "source_response_id" => response.id, "requested_at" => date.noon.utc.iso8601(6) }
    })
  end

  def committed_turns(user, count:)
    count.times.map do |index|
      date = start + index
      travel_to(date.noon) do
        language = user.language_for_today
        context = PracticeGeneration.capture(user, date: date)
        expect(context.fetch(:evidence).fetch(:pending)).not_to be_empty
        plan = DailyPlan.for(user, language: language, schedule_context: context)
        kind = plan.kinds.sole
        section = { "question" => "Generated exercise", "snippet" => "def call; work; end" }
        section["purpose"] = "Find the defect in this operation" if kind == ExerciseSection::CodeReview && plan.code_review_mode == :bug_hunt
        judged = AiService::JudgedSet.new(problem_set: { kind.key => section }, dropped_sections: [], outcomes: {},
          schedule_context: context, plan_notes: plan.notes)
        committed = PracticeGeneration.commit_new(user, context: context, judged: judged, language: language, drafted_by: nil)
        expect(committed.status).to eq(:saved)
        expect(committed.exercise.reload.practice_schedule.fetch("selected_kinds")).to eq([ kind.key ])
        { date: date, language: language, kind: kind.key, core: kind.mastery_evidence?(section), assignments: plan.assignments.values }
      end
    end
  end

  def expect_bounded_variety(turns, pool)
    pool.each do |kind|
      served = turns.each_index.select { |index| turns[index][:kind] == kind.key }
      gaps = ([ -1 ] + served + [ turns.size ]).each_cons(2).map { |left, right| right - left }
      expect(gaps.max).to be <= pool.size * 2
    end
  end
end
