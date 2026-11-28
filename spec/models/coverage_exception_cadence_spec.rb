require "rails_helper"

# Historical coverage keeps its cadence even though new sessions no longer add coverage sections.
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
    it "matches the historical planner's steady recurrence with #{excluded.size} kinds excluded" do
      preferences = KindPreferences.new(weights: {}, excluded: excluded)
      candidates  = described_class.candidate_kinds(daily: daily, preferences: preferences)
      gaps        = steady_gaps(simulate(preferences))

      expect(gaps).to eq([ described_class.expected_gap_weekdays(candidates: candidates.size) ])
    end
  end
end
