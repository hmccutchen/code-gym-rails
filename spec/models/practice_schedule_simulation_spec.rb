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

  it "feeds actual offered weekday dates and strict evidence into the own-kind selector" do
    run_weekdays(ease_first: false)
  end

  it "requires five normal results after the first eased attempt without changing workload" do
    run_weekdays(ease_first: true)
  end
end
