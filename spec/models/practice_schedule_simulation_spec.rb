require "rails_helper"

RSpec.describe "Protected-practice opportunity simulation", type: :model do
  def selection(previous, pair:, struggle: {}, reviewed: 2, preferences: KindPreferences.none)
    PracticeSchedule.plan(context: previous, count: DailyKinds::COUNT, setting: nil, daily: pair,
      preferences: preferences, evidence: { initial_reviewed_sets: reviewed, struggle: struggle, pending: [] },
      hosts: DayHosts.new("ruby_rails", mode: :application_code), rotation_history: [], due: [], drills: [])
  end

  it "bounds stable cross-round gaps for every valid regular pair, with lone and shared struggle" do
    pools = []
    ExerciseSection.all.combination(DailyKinds::COUNT).each do |pair|
      next unless DailyKinds.problems_with(pair.map(&:key)).empty?

      candidates = ExerciseSection.optional_slots(daily: pair).values.flatten
      [ { pair.first.key => true }, pair.map(&:key).index_with { true } ].each do |struggle|
        previous = nil
        seen = Hash.new { |hash, key| hash[key] = [] }
        omitted = nil
        (PracticeSchedule::Turns::CYCLE * candidates.size * 3).times do |index|
          result = selection(previous, pair: pair, struggle: struggle)
          expect(result.kinds.size).to eq(DailyKinds::COUNT)
          expect(result.kinds).to include(pair.first) if struggle.size == 1
          expect(result.kinds.map(&:key)).to include(omitted) if omitted
          omitted = result.notes["omitted_kind"]
          result.kinds.each { |kind| seen[kind.key] << index if candidates.include?(kind) }
          previous = result.notes
        end
        expect(seen.keys).to match_array(candidates.map(&:key))
        gaps = seen.transform_values { |turns| turns.each_cons(2).map { |a, b| b - a }.max }
        expect(gaps.values).to all(be <= PracticeSchedule::Turns::CYCLE * candidates.size)
        pools << { pair: pair.map(&:key), candidates: candidates.map(&:key), maximum_gap: gaps.values.max } if struggle.size == 1
      end
    end
    puts "PRACTICE_MEASUREMENT pools=#{pools.to_json}"
  end

  it "preserves exclusions and bounds for every pair with narrowed and empty alternative pools" do
    checked = 0
    ExerciseSection.all.combination(DailyKinds::COUNT).each do |pair|
      next unless DailyKinds.problems_with(pair.map(&:key)).empty?

      alternatives = ExerciseSection.optional_slots(daily: pair).values.flatten
      [ alternatives.first(1), alternatives.drop(1), alternatives ].uniq.each do |excluded|
        preferences = KindPreferences.new(weights: {}, excluded: excluded.map(&:key))
        pool = alternatives - excluded
        previous = nil
        seen = Hash.new { |hash, key| hash[key] = [] }
        (PracticeSchedule::Turns::CYCLE * [ pool.size, 1 ].max * 2).times do |index|
          result = selection(previous, pair: pair, preferences: preferences)
          expect(result.kinds & excluded).to be_empty
          expect(result.kinds.size).to eq(DailyKinds::COUNT)
          result.kinds.each { |kind| seen[kind.key] << index if pool.include?(kind) }
          previous = result.notes
        end
        expect(seen.keys).to match_array(pool.map(&:key))
        seen.each_value do |turns|
          expect(turns.each_cons(2).map { |a, b| b - a }).to all(be <= PracticeSchedule::Turns::CYCLE * pool.size)
        end
        checked += 1
      end
    end
    puts "PRACTICE_MEASUREMENT exclusion_variants=#{checked}"
  end

  def run_weekdays(ease_first:)
    user = create_user_with_key
    pair = DailyKinds::DEFAULT
    pool = ExerciseSection.optional_slots(daily: pair).values.flatten
    date = Date.new(2026, 1, 5)
    previous = nil
    seen = Hash.new { |hash, key| hash[key] = [] }
    report = {}
    last_set = PracticeSchedule::Turns::CYCLE * (LevelSuggestion::WINDOW + (ease_first ? 1 : 0)) * pool.size
    last_set.times do |index|
      facts = PracticeEvidence.for(user, before: date)
      selected = selection(previous, pair: pair, reviewed: facts.fetch(:initial_reviewed_sets))
      data = selected.kinds.to_h do |kind|
        section = { "question" => "Explain the decision", "snippet" => "x = 1", "blocks" => %w[a b],
          "pitched_at" => "junior", "concept" => ConceptVocabulary.for_section(kind.key, "ruby_rails").first }
        section["eased"] = true if ease_first && pool.include?(kind) && seen[kind.key].empty?
        [ kind.key, section ]
      end
      exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, problem_set: data,
        plan_notes: { "daily_kinds" => pair.map(&:key), "practice_schedule" => selected.notes })
      user.daily_responses.create!(date: date, daily_exercise: exercise, submitted_at: Time.current,
        answers: selected.kinds.to_h { |kind| [ kind.key, kind == ExerciseSection::ParsonsProblem ? "order:1,0" : "Explain the constraints and tradeoffs." ] },
        section_ratings: data.keys.index_with { "right_level" }, concept_tags: data.transform_values { |section| section["concept"] },
        ai_review: data.keys.index_with { { "rating" => "solid", "rubric" => ReviewedSectionResults::RUBRIC_VERSION } })
      selected.kinds.each do |kind|
        next unless pool.include?(kind)

        seen[kind.key] << { set: index + 1, date: date, eased: data[kind.key]["eased"] == true }
        normal = seen[kind.key].reject { |entry| entry[:eased] }
        next unless normal.size == LevelSuggestion::WINDOW && !report.key?(kind.key)

        results = LevelSuggestion::Evidence.for(user, today: date).results
        expect(results.fetch(kind.key).size).to eq(LevelSuggestion::WINDOW)
        offer = LevelSuggestion.proposal(levels: { kind.key => "junior" }, locked: [], results: results, cutoffs: {}, today: date)
        expect(offer.steps.map(&:kind)).to include(kind.key)
        report[kind.key] = { first: seen[kind.key].first, first_normal: normal.first, fifth: normal.last }
      end
      previous = selected.notes
      date += 1
      date += 1 while date.on_weekend?
    end
    expect(report.keys).to match_array(pool.map(&:key))
    expect(report.values.map { |entry| entry[:fifth][:set] }.max).to eq(last_set)
    puts "PRACTICE_MEASUREMENT weekdays_eased_first=#{ease_first} results=#{report.to_json} workload=#{DailyKinds::COUNT} candidates=#{pool.size}"
  end

  it "takes a real eased review through a pending protected normal retry, ingest and normal assessment at two sections" do
    user = create_user_with_key
    user.update!(daily_section_count: 2, daily_section_kinds: %w[pattern code_review], skill_level: "junior")
    pair = DailyKinds.for(user)
    date = Date.new(2026, 11, 2)
    reviewer = Object.new
    reviewer.define_singleton_method(:review_sections) do |*_args, sections:|
      sections.index_with { { ok: true, review: { "rating" => "solid", "rubric" => ReviewedSectionResults::RUBRIC_VERSION } } }
    end
    save_and_review = lambda do |day, set, notes, &before_review|
      exercise = user.daily_exercises.create!(date: day, generated_at: Time.current, problem_set: set, plan_notes: notes)
      expect(exercise.active_section_keys.size).to eq(2)
      response = user.daily_responses.create!(date: day, daily_exercise: exercise, submitted_at: Time.current,
        answers: set.keys.index_with { "Explain the decision and its tradeoffs." },
        section_ratings: set.keys.index_with { "right_level" }, concept_tags: set.transform_values { |section| section["concept"] })
      before_review&.call
      expect(ResponseReview.new(response, user: user, reviewer: reviewer).call.status).to eq(:ready)
      response
    end
    assignments = { "pattern" => { concept: "service_objects", bucket: "ruby_rails", mode: "simplified" } }
    rungs = pair.map(&:key).index_with { "junior" }
    initial_adjustment = PracticeAdjustment.resolve(assignments: assignments, difficulty: KindDifficulty.none, rungs: rungs, reduced: {})
    payload = FakeService::EXERCISE_PROBLEM_SET.slice(*rungs.keys).deep_dup
    first = ProblemSetIngest.call(payload, language: "ruby_rails", expected_keys: rungs.keys, daily: pair,
      pitched_at: rungs, assignments: initial_adjustment).problem_set
    expect(first.dig("pattern", "eased")).to be(true)
    travel_to(date.noon) { save_and_review.call(date, first, { "daily_kinds" => pair.map(&:key) }) }
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
    row = user.concept_masteries.find_by!(concept: "service_objects", language: "ruby_rails")
    request = row.practice_requests.deep_dup
    expect(request).to include("pattern" => include("mode" => "normal_retry"))
    expect(row.mastered_at).to be_nil
    expect(LevelSuggestion::Evidence.for(user, today: date).results.fetch("pattern", [])).to be_empty
    facts = PracticeEvidence.for(user, before: date + 1, kinds: pair.map(&:key))
    expect(facts[:pending].sole).to include(kind: "pattern", concept: "service_objects", mode: "normal_retry")
    selected = PracticeSchedule.plan(context: nil, count: 2, setting: 2, daily: pair,
      preferences: KindPreferences.none, evidence: facts, hosts: DayHosts.new("ruby_rails", mode: :application_code),
      rotation_history: [], due: [], drills: [])
    expect(selected.assignments.fetch("pattern")).to include(reason: "normal_retry", concept: "service_objects")
    resolved = PracticeAdjustment.resolve(assignments: selected.assignments, difficulty: KindDifficulty.none,
      rungs: rungs, reduced: { "pattern" => %w[service_objects] })
    expect(resolved.fetch("pattern")).to include(mode: "normal_retry", eased: false)
    retry_set = ProblemSetIngest.call(payload.deep_dup, language: "ruby_rails", expected_keys: rungs.keys, daily: pair,
      pitched_at: rungs, assignments: resolved, eased_for: { "pattern" => %w[service_objects] },
      fixed_concepts: { "pattern" => "service_objects" }).problem_set
    expect(retry_set.dig("pattern", "eased")).not_to be(true)
    expect(retry_set.dig("pattern", "practice_adjustment")).to eq("normal_retry")
    travel_to((date + 1).noon) do
      save_and_review.call(date + 1, retry_set, { "daily_kinds" => pair.map(&:key), "practice_schedule" => selected.notes }) do
        expect(row.reload.practice_requests).to eq(request)
      end
    end
    expect(row.reload.practice_requests).to eq({})
    expect(row.mastered_at).to be_present
    normal = LevelSuggestion::Evidence.for(user, today: date + 1).results.fetch("pattern")
    expect(normal.map(&:date)).to eq([ date + 1 ])
    puts "PRACTICE_MEASUREMENT protected_retry=#{ { concept: row.concept, first_eased_on: date, first_normal_on: normal.sole.date,
      normal_opportunity: 2, workload: 2, pending_after_review: row.practice_requests.size }.to_json }"
  end

  it "feeds actual offered weekday dates and strict evidence into the own-kind selector" do
    run_weekdays(ease_first: false)
  end

  it "requires five normal results after the first eased attempt without changing workload" do
    run_weekdays(ease_first: true)
  end
end
