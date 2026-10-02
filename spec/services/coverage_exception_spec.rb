require "rails_helper"

RSpec.describe CoverageException do
  let(:monday) { Date.new(2026, 10, 5) }
  let(:hosts) { DayHosts.new("ruby_rails", mode: :application_code) }
  let(:optional_keys) { described_class::OPTIONAL_KINDS.map(&:key) }

  def weekdays_ago(count)
    date = monday
    count.times { date = date.prev_day; date = date.prev_day until date.on_weekday? }
    date
  end

  # Every optional kind seen yesterday unless overridden, from a long history.
  def history(last_seen: {}, coverage_dates: [], first_date: monday - 200)
    seen = optional_keys.index_with { weekdays_ago(1) }.merge(last_seen).compact
    CoverageException::History.new(last_seen: seen, coverage_dates: coverage_dates, first_date: first_date)
  end

  def decide(history: self.history, checks: [], count: ExerciseSection.fixed.size, fixed: nil, brake: false,
             preferences: KindPreferences.none)
    described_class.for(today: monday, count: count, fixed: fixed, history: history, checks: checks,
                        preferences: preferences, hosts: hosts, brake: brake)
  end

  def overdue(concept, bucket, ratio: 2.0)
    { concept: concept, bucket: bucket, overdue_ratio: ratio }
  end

  describe "a long gap" do
    it "adds a kind unseen for one weekday more than the gap, and not at the gap itself" do
      at_gap  = decide(history: history(last_seen: { "pattern" => weekdays_ago(described_class::GAP_WEEKDAYS) }))
      past_it = decide(history: history(last_seen: { "pattern" => weekdays_ago(described_class::GAP_WEEKDAYS + 1) }))

      expect(at_gap).to be_nil
      expect(past_it).to eq(described_class::Addition.new(kind: ExerciseSection::Pattern, reason: :gap))
    end

    it "takes the longest gap, a kind never seen first, and breaks ties by registry order" do
      never = history(last_seen: { "plan_review" => nil, "architecture" => nil, "pattern" => weekdays_ago(40) })

      expect(decide(history: never).kind).to eq(ExerciseSection::Architecture)
    end

    it "measures a never-seen kind from the oldest exercise read, so a new account gains nothing" do
      fresh = history(last_seen: optional_keys.index_with { nil }, first_date: weekdays_ago(5))

      expect(decide(history: fresh)).to be_nil
      expect(decide(history: CoverageException::History.new(last_seen: {}, coverage_dates: [], first_date: nil))).to be_nil
    end

    it "never adds a kind the user excluded" do
      stale = history(last_seen: { "pattern" => weekdays_ago(30), "plan_review" => weekdays_ago(25) })
      preferences = KindPreferences.new(weights: {}, excluded: [ "pattern" ])

      expect(decide(history: stale, preferences: preferences).kind).to eq(ExerciseSection::PlanReview)
    end
  end

  describe "a waiting retention check" do
    it "is preferred over a gap, and names the kind that can host it" do
      stale = history(last_seen: { "pattern" => weekdays_ago(30) })

      addition = decide(history: stale, checks: [ overdue("service_boundaries", "architecture") ])

      expect(addition).to eq(described_class::Addition.new(kind: ExerciseSection::Architecture, reason: :due_check))
    end

    it "counts only checks past the meaningful-overdue threshold" do
      merely_due = overdue("service_boundaries", "architecture",
                           ratio: ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER - 0.5)

      expect(decide(checks: [ merely_due ])).to be_nil
    end

    it "takes the most overdue check first" do
      checks = [ overdue("service_boundaries", "architecture", ratio: 2.0), overdue("scope_creep", "plan_review", ratio: 3.0) ]

      expect(decide(checks: checks).kind).to eq(ExerciseSection::PlanReview)
    end

    it "skips a check no optional kind can host today and moves to the next" do
      checks = [ overdue("closures", "javascript", ratio: 9.0), overdue("scope_creep", "plan_review") ]

      expect(decide(checks: checks).kind).to eq(ExerciseSection::PlanReview)
    end

    it "skips a check whose only host the user excluded" do
      preferences = KindPreferences.new(weights: {}, excluded: [ "architecture" ])

      expect(decide(checks: [ overdue("service_boundaries", "architecture") ], preferences: preferences)).to be_nil
    end

    it "hosts a language check in the stalest kind that can tag it" do
      stale = history(last_seen: { "security_review" => weekdays_ago(3), "challenge" => weekdays_ago(8) })

      expect(decide(history: stale, checks: [ overdue("memoization", "ruby_rails") ]).kind).to eq(ExerciseSection::Challenge)
    end
  end

  describe "when it applies" do
    let(:stale) { history(last_seen: { "pattern" => weekdays_ago(30) }) }

    it "never fires under a fixed setting, even at two sections" do
      expect(decide(history: stale, fixed: 2)).to be_nil
    end

    it "reads the day's size against the fixed kinds, the authority for having no optional slot" do
      expect(described_class.applies_to_day?(count: ExerciseSection.fixed.size, fixed: nil)).to be(true)
      expect(described_class.applies_to_day?(count: ExerciseSection.fixed.size + 1, fixed: nil)).to be(false)
    end

    it "never fires on a day above two sections" do
      expect(decide(history: stale, count: ExerciseSection.fixed.size + 1)).to be_nil
    end

    it "never fires while the brake is on" do
      expect(decide(history: stale, brake: true)).to be_nil
    end
  end

  describe "the four-weekday cap" do
    let(:stale) { history(last_seen: { "pattern" => weekdays_ago(30) }, coverage_dates: coverage_dates) }

    context "with an addition on the fourth weekday back, across a weekend" do
      let(:coverage_dates) { [ weekdays_ago(4) ] }

      it "holds the day at two" do
        expect(weekdays_ago(4)).to eq(Date.new(2026, 9, 29))
        expect(decide(history: stale)).to be_nil
      end
    end

    context "with an addition on the fifth weekday back" do
      let(:coverage_dates) { [ weekdays_ago(5) ] }

      it "fires again" do
        expect(decide(history: stale)).not_to be_nil
      end
    end

    context "with an addition on a weekend inside the window" do
      let(:coverage_dates) { [ Date.new(2026, 10, 3) ] }

      it "still counts it, since it is only a date" do
        expect(decide(history: stale)).to be_nil
      end
    end

    # A paused stretch leaves no rows, and its weekdays still pass.
    context "with an addition before a paused week" do
      let(:coverage_dates) { [ weekdays_ago(6) ] }

      it "fires once the stretch has run past four weekdays" do
        expect(decide(history: stale)).not_to be_nil
      end
    end
  end
end
