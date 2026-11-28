require "rails_helper"

RSpec.describe "Mixed-language single-slot liveness", type: :model do
  it "eventually serves a valid kind-specific request in the other language" do
    user = User.create!(email: "mixed-liveness@example.com", language: "javascript")
    start = Date.new(2026, 11, 2)
    source = user.daily_exercises.create!(date: start - 2, language: "javascript", generated_at: Time.current,
      section_order: [ "code_review" ], problem_set: { "code_review" => { "concept" => "closures" } })
    response = user.daily_responses.create!(daily_exercise: source, date: source.date, submitted_at: Time.current,
      answers: { "code_review" => "A closure captures its lexical environment." },
      section_ratings: { "code_review" => "too_hard" }, concept_tags: { "code_review" => "closures" },
      ai_review: { "code_review" => { "rating" => "solid" } })
    user.concept_masteries.create!(concept: "closures", language: "javascript", practice_requests: {
      "code_review" => { "mode" => "support", "source_response_id" => response.id, "requested_at" => Time.current.utc.iso8601(6) }
    })
    user.daily_exercises.create!(date: start - 1, language: "javascript", generated_at: Time.current,
      section_order: [ "pattern" ], problem_set: { "pattern" => { "concept" => "closures" } })
    user.update!(language: "mixed")
    pool = KindPreferences.for(user).offered(daily: DailyKinds.for(user))
    expect(pool.size).to be_even
    previous = {}
    selections = []
    assignments = []
    (pool.size * 10).times do |index|
      date = start + index * 7
      travel_to(date.noon) do
        language = user.language_for_today
        hosts = DayHosts.new(language, mode: :application_code)
        pending = PracticeEvidence.pending_for(user)
        expect(pending.sole).to include(kind: "code_review", concept: "closures", bucket: "javascript", mode: "support")
        expect(hosts.can_tag?(ExerciseSection::CodeReview, "closures", "javascript")).to eq(language == "javascript")
        selected = PracticeSchedule.single_plan(context: previous, daily: DailyKinds.for(user),
          preferences: KindPreferences.for(user), evidence: { initial_reviewed_sets: 0, struggle: {}, pending: pending },
          hosts: hosts, rotation_history: user.recent_exercise_history(limit: SectionRotation::LOOKBACK, language: language), due: [], drills: [])
        key = selected.kinds.sole.key
        selections << [ key, language ]
        assignments.concat(selected.assignments.values)
        user.daily_exercises.create!(date: date, language: language, generated_at: Time.current,
          section_order: [ key ], problem_set: { key => {} }, plan_notes: { "practice_schedule" => selected.notes })
        previous = PracticeSchedule.context_for(user)
      end
    end
    selections.group_by(&:last).each_value do |language_turns|
      language_turns.each_slice(pool.size) { |round| expect(round.map(&:first)).to match_array(pool.map(&:key)) }
    end
    expect(assignments).to include(a_hash_including(kind: "code_review", concept: "closures", bucket: "javascript"))
  end
end

RSpec.describe DailyPlan, "language-specific delivered history" do
  it "seeds inactive scheduling from the generated language before applying its history limit" do
    user = User.create!(email: "language-history@example.com", language: "mixed")
    (ExerciseSection.all - [ ExerciseSection::CodeReview ]).each_with_index do |kind, index|
      user.daily_exercises.create!(date: Date.current - 2 - index, generated_at: 2.days.ago, language: "ruby_rails",
        section_order: [ kind.key ], problem_set: { kind.key => {} })
    end
    user.daily_exercises.create!(date: Date.yesterday, generated_at: 1.day.ago, language: "javascript",
      section_order: [ "code_review" ], problem_set: { "code_review" => {} })

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.kinds).to eq([ ExerciseSection::CodeReview ])
    expect(plan.practice_schedule).to be_nil
    expect(user.recent_exercise_history(limit: 1, language: "ruby_rails").sole.delivered_section_keys).to eq([ (ExerciseSection.all - [ ExerciseSection::CodeReview ]).first.key ])
  end
end


RSpec.describe "Mixed-language assignment liveness" do
  it "serves both pending practice and retention in each generated language" do
    kind = ExerciseSection::CodeReview
    preferences = KindPreferences.none
    pending = [ { kind: kind.key, concept: "service_objects", bucket: "ruby_rails", mode: "support" },
      { kind: kind.key, concept: "closures", bucket: "javascript", mode: "support" } ]
    due = [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 2 },
      { concept: "closures", bucket: "javascript", overdue_ratio: 2 } ]
    previous = {}
    reasons = Hash.new { |h, k| h[k] = [] }
    (ExerciseSection.pickable(daily: DailyKinds::DEFAULT).size * 4).times do |index|
      language = DailyExercise::LANGUAGES[index % DailyExercise::LANGUAGES.size]
      selection = PracticeSchedule.single_plan(context: previous, daily: DailyKinds::DEFAULT, preferences: preferences,
        evidence: { initial_reviewed_sets: 0, pending: pending, struggle: {} }, hosts: DayHosts.new(language, mode: :application_code),
        rotation_history: [], due: due, drills: [])
      previous = selection.notes
      reasons[language] << selection.assignments.fetch(kind.key).fetch(:reason) if selection.assignments.key?(kind.key)
    end
    reasons.each_value { |entries| expect(entries).to include("support", "retention") }
  end
end
