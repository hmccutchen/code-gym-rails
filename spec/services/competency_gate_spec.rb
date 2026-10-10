require "rails_helper"

RSpec.describe CompetencyGate do
  let(:fixed) { %w[code_review design_comparison] }

  def result(kind = "code_review", level: "senior", ai: "solid", self_rating: "right_level", eased: false)
    ReviewedSectionResults::Result.new(date: nil, kind: kind, level: level, ai_rating: ai, self_rating: self_rating, eased: eased)
  end

  def good(kind = "code_review", level: "senior") = result(kind, level: level)
  def poor(kind = "code_review", level: "senior") = result(kind, level: level, ai: "developing")
  def too_hard(kind = "code_review", level: "senior", eased: false)
    result(kind, level: level, self_rating: "too_hard", eased: eased)
  end

  def day(*results, optional: :none)
    CompetencyGate::Day.new(results: results, optional: optional)
  end

  def counts(days)
    described_class.plans(days, fixed_kinds: fixed).map(&:count)
  end

  it "starts at two with zero evidence" do
    plan = described_class.plan([], fixed_kinds: fixed)

    expect(plan.count).to eq(2)
    expect(plan.reason).to eq(:held)
    expect(plan.evidence).to eq(
      to_three: { required: 5, available: 0, bar_met: 0, favourable: 0, by_kind: {} },
      to_four: { required: 10, available: 0, bar_met: 0, favourable: 0, by_kind: {} },
      brake: { required: 4, available: 0, too_hard: 0 },
      optional: { required: 2, available: 0, complete: 0 },
      levels: {}
    )
  end

  it "states its starting policy" do
    expect(described_class::BAR).to eq("solid")
    expect(described_class::GROW_TO_THREE).to eq(CompetencyGate::Threshold.new(at_least: 4, of: 5))
    expect(described_class::GROW_TO_FOUR).to eq(CompetencyGate::Threshold.new(at_least: 8, of: 10))
    expect(described_class::OPTIONAL_RUN).to eq(2)
    expect(described_class::BRAKE).to eq(CompetencyGate::Threshold.new(at_least: 2, of: 4))
  end

  # Otherwise a rule would reach past the ceiling or leave a size no rule earns.
  it "grows no further than the most sections one day holds" do
    expect(described_class::FLOOR + described_class::GROWTH.size).to eq(ExerciseSection::MAX_SECTIONS)
  end

  it "reads its AI bar on the mastery rating rank" do
    expect(ConceptMastery::AI_RATING_RANK).to have_key(described_class::BAR)
  end

  describe "growing to three" do
    it "does not grow on 3 favourable of the latest 5" do
      expect(counts([ good, poor, good, poor, good ].map { |r| day(r) })).to all(eq(2))
    end

    it "grows on 4 favourable of the latest 5, on the day the window fills" do
      expect(counts([ poor, good, good, good, good ].map { |r| day(r) })).to eq([ 2, 2, 2, 2, 3 ])
    end

    it "does not grow on 4 favourable of 4, since the window is not full" do
      expect(counts(Array.new(4) { day(good) })).to all(eq(2))
    end

    it "counts favourable results across the fixed kinds combined" do
      days = [ day(good, poor("design_comparison")), day(good, good("design_comparison")), day(good) ]

      expect(counts(days)).to eq([ 2, 2, 3 ])
    end

    it "takes no growth evidence from optional kinds" do
      expect(counts(Array.new(5) { day(good("pattern"), good("challenge")) })).to all(eq(2))
    end

    # An eased section answered an easier question, so its AI rating says nothing about the rung.
    it "takes no growth evidence from eased sections" do
      eased = Array.new(5) { day(result(eased: true)) }

      expect(counts(eased)).to all(eq(2))
      expect(described_class.plan(eased, fixed_kinds: fixed).evidence[:to_three]).to include(available: 0)
    end

    it "moves at most one step a day" do
      expect(counts([ day(*Array.new(10) { good }, optional: :complete) ])).to eq([ 3 ])
    end
  end

  describe "growing to four" do
    def days_with(pattern, optional: :complete)
      pattern.chars.map { |mark| day(mark == "G" ? good : poor, optional: optional) }
    end

    it "does not reach four on 7 favourable of the latest 10" do
      expect(counts(days_with("PPPGGGGGGG"))).to eq([ 2, 2, 2, 2, 2, 2, 3, 3, 3, 3 ])
    end

    it "reaches four on 8 favourable of the latest 10 with the optional section answered on both of the last two days" do
      expect(counts(days_with("PPGGGGGGGG"))).to eq([ 2, 2, 2, 2, 2, 3, 3, 3, 3, 4 ])
    end

    it "holds at three while fewer than two days have had an optional section" do
      days = days_with("PPGGGGGGGG", optional: :none)
      days[-1] = day(good, optional: :complete)

      expect(counts(days).last).to eq(3)
    end

    it "holds at three when either of the last two days with an optional section left one unanswered" do
      days = days_with("PPGGGGGGGG")
      days[-2] = day(good, optional: :incomplete)

      expect(counts(days).last).to eq(3)
    end

    it "skips days without an optional section when finding the last two that had one" do
      days = days_with("PPGGGGGG") + [ day(good, optional: :none), day(good, optional: :none) ]

      expect(counts(days).last).to eq(4)
    end

    it "never grows past the most sections a day holds" do
      expect(counts(days_with("GGGGGGGGGGGGGGG")).last(3)).to all(eq(ExerciseSection::MAX_SECTIONS))
    end
  end

  describe "the brake" do
    def earned_three = Array.new(5) { day(good) }

    it "returns to two when 2 of the latest 4 results are too hard" do
      plans = described_class.plans(earned_three + [ day(too_hard), day(too_hard) ], fixed_kinds: fixed)

      expect(plans.map(&:count)).to eq([ 2, 2, 2, 2, 3, 3, 2 ])
      expect(plans.last.reason).to eq(:brake)
    end

    it "reads optional kinds too" do
      expect(counts(earned_three + [ day(too_hard("pattern")), day(too_hard("challenge")) ]).last).to eq(2)
    end

    it "needs four eligible results, so two too-hard results of three hold" do
      plans = described_class.plans([ day(too_hard), day(too_hard), day(good) ], fixed_kinds: fixed)

      expect(plans.map(&:reason)).to all(eq(:held))
    end

    it "needs four results at the current level after a level change" do
      days = earned_three + [ day(too_hard(level: "principal_engineer")), day(too_hard(level: "principal_engineer")) ]

      expect(counts(days).last(2)).to eq([ 3, 3 ])
    end

    it "takes precedence over growth on the same day" do
      grows = Array.new(5) { day(good) }
      days = Array.new(3) { day(good) } + Array.new(2) { day(good, too_hard("pattern")) }

      expect(described_class.plan(grows, fixed_kinds: fixed).count).to eq(3)
      expect(described_class.plan(days, fixed_kinds: fixed)).to have_attributes(count: 2, reason: :brake)
    end

    # Otherwise struggling only on optional sections would swing the day 3, 2, 3.
    it "needs a fresh fixed-kind window before growing again" do
      both = -> { day(good, good("design_comparison")) }
      days = earned_three + [ day(too_hard("pattern"), too_hard("challenge")) ] + Array.new(4) { both.call }

      expect(counts(days)).to eq([ 2, 2, 2, 2, 3, 2, 2, 2, 2, 3 ])
      expect(described_class.plans(days, fixed_kinds: fixed).map(&:reason).last(5)).to eq(%i[brake brake held held grew])
    end

    it "restarts the growth window on every day the brake holds" do
      plan = described_class.plan(earned_three + [ day(too_hard), day(too_hard) ], fixed_kinds: fixed)

      expect(plan.evidence[:to_three]).to include(available: 0, favourable: 0)
      expect(plan.evidence[:brake]).to include(available: 4, too_hard: 2)
    end

    it "reads an eased section's too-hard self-rating" do
      days = earned_three + [ day(too_hard(eased: true)), day(too_hard("pattern", eased: true)) ]

      expect(described_class.plan(days, fixed_kinds: fixed)).to have_attributes(count: 2, reason: :brake)
    end

    it "holds a later day at two while the too-hard results stay in the window" do
      days = earned_three + [ day(too_hard), day(too_hard), day(good) ]

      expect(described_class.plan(days, fixed_kinds: fixed).reason).to eq(:brake)
    end
  end

  describe "level changes" do
    it "keeps an earned three on and after the day a kind changes level without new evidence" do
      days = Array.new(5) { day(good) } + Array.new(3) { day(good(level: "principal_engineer")) }

      expect(counts(days)).to eq([ 2, 2, 2, 2, 3, 3, 3, 3 ])
    end

    it "does not reuse a rung's earlier evidence when a kind returns to it" do
      days = Array.new(3) { day(good) } + [ day(good(level: "junior")) ] + Array.new(2) { day(good) }

      expect(counts(days)).to all(eq(2))
    end

    it "keeps an unchanged kind's evidence while another kind starts over" do
      days = [
        day(good, good("design_comparison")),
        day(good, good("design_comparison")),
        day(good, good("design_comparison", level: "junior")),
        day(good)
      ]

      plans = described_class.plans(days, fixed_kinds: fixed, evidence: true)
      expect(plans.map(&:count)).to eq([ 2, 2, 2, 3 ])
      expect(plans.last.evidence[:to_three][:by_kind]).to eq("code_review" => 4, "design_comparison" => 1)
      expect(plans.last.evidence[:levels]).to eq("code_review" => "senior", "design_comparison" => "junior")
    end
  end

  it "never changes an earlier day's plan when a day is appended" do
    days = Array.new(5) { day(good) } + [ day(too_hard), day(too_hard(level: "junior")) ]

    days.size.times do |n|
      expect(described_class.plans(days.first(n), fixed_kinds: fixed))
        .to eq(described_class.plans(days, fixed_kinds: fixed).first(n))
    end
  end

  describe "favourable results" do
    it "needs the AI bar and a favourable self-rating together" do
      days = [
        day(result(ai: "strong", self_rating: "too_easy")),
        day(result(ai: "solid")),
        day(result(ai: "strong")),
        day(result(ai: "solid", self_rating: "too_hard")),
        day(result(ai: "developing"))
      ]

      expect(described_class.plan(days, fixed_kinds: fixed).evidence[:to_three])
        .to eq(required: 5, available: 5, bar_met: 4, favourable: 3, by_kind: { "code_review" => 5 })
    end

    it "never counts a missing or invalid self-rating as favourable" do
      days = [ nil, "meh", "Right_level", nil, "meh" ].map { |rating| day(result(self_rating: rating)) }
      plan = described_class.plan(days, fixed_kinds: fixed)

      expect(plan.evidence[:to_three]).to include(bar_met: 5, favourable: 0)
      expect(plan.count).to eq(2)
    end
  end

  it "reports the optional run it read" do
    days = [ day(good, optional: :complete), day(good, optional: :incomplete), day(good) ]

    expect(described_class.plan(days, fixed_kinds: fixed).evidence[:optional])
      .to eq(required: 2, available: 2, complete: 1)
  end

  it "refuses an optional state it does not know" do
    expect { day(good, optional: true) }.to raise_error(ArgumentError, /optional/)
  end

  it "builds evidence only for the plans asked for" do
    days = Array.new(6) { day(good) }

    expect(described_class.plans(days, fixed_kinds: fixed).map(&:evidence)).to all(be_nil)
    expect(described_class.plans(days, fixed_kinds: fixed, evidence: true).map(&:evidence)).to all(include(:to_three))
    expect(described_class.plan(days, fixed_kinds: fixed).evidence).to include(:to_three)
  end

  it "folds the same way one day at a time" do
    days = Array.new(5) { day(good) } + [ day(too_hard), day(too_hard) ]
    gate = described_class.new(fixed_kinds: fixed)

    expect(days.map { |each_day| gate.add(each_day).plan(evidence: false) }).to eq(described_class.plans(days, fixed_kinds: fixed))
    expect(gate.plan).to eq(described_class.plan(days, fixed_kinds: fixed))
  end
end
