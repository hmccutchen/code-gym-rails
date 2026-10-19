require "rails_helper"

# Drives the real planner over synthetic weekdays, so the swap picker's weeks figure can't drift from what coverage does.
RSpec.describe CoverageException, ".expected_gap_weekdays" do
  let(:daily) { [ ExerciseSection::Challenge, ExerciseSection::DesignComparison ] }
  let(:start) { Date.new(2026, 1, 5) }
  let(:weekdays) { 400 }

  def simulate(preferences)
    last_seen = {}
    coverage = []
    seen_on = Hash.new { |hash, key| hash[key] = [] }

    (start..).lazy.select(&:on_weekday?).first(weekdays).each do |date|
      history  = CoverageException::History.new(last_seen: last_seen.dup, coverage_dates: coverage, first_date: start - 60)
      addition = described_class.for(today: date, count: DailyKinds::COUNT, fixed: nil, history: history, checks: [],
                                     preferences: preferences, hosts: nil, daily: daily)
      if addition
        coverage << date
        seen_on[addition.kind.key] << date
        last_seen[addition.kind.key] = date
      end
      daily.each { |kind| last_seen[kind.key] = date }
    end
    seen_on
  end

  def steady_gaps(seen_on)
    seen_on.values.flat_map { |dates| dates.drop(2).each_cons(2).map { |from, to| (from.next_day..to).count(&:on_weekday?) } }.uniq
  end

  [ [], %w[security_review parsons_problem pattern], %w[security_review parsons_problem pattern architecture plan_review ambiguity_hunt],
    %w[security_review parsons_problem pattern architecture plan_review ambiguity_hunt pseudocode_to_code] ].each do |excluded|
    it "matches the planner's steady recurrence with #{excluded.size} kinds excluded" do
      preferences = KindPreferences.new(weights: {}, excluded: excluded)
      candidates  = described_class.candidate_kinds(daily: daily, preferences: preferences)
      gaps        = steady_gaps(simulate(preferences))

      expect(gaps).to eq([ described_class.expected_gap_weekdays(candidates: candidates.size) ])

      warning = DailyKindSwap::Consequences.for(
        pair: DailyKinds::DEFAULT, place: 0, kind: ExerciseSection::Challenge, preferences: preferences,
        day: DailyKindSwap::Consequences::Day.new(setting: nil, planned_size: DailyKinds::COUNT, brake: false),
        languages: %w[ruby_rails], pair_shares: false
      ).warning
      weeks = (gaps.first.to_f / DailyKindSwap::Consequences::WEEKDAYS_PER_WEEK).round
      expect(warning.first).to include("about once every #{weeks} weeks")
    end
  end
end
