require "rails_helper"

RSpec.describe SectionRotation do
  def history(*key_sets)
    key_sets.map do |keys|
      ExerciseHistoryEntry.new(section_keys: keys, delivered_section_keys: keys, answered: keys.size, dropped: 0)
    end
  end

  it "fills every optional slot at full size" do
    chosen = described_class.for(history, count: 4)

    expect(chosen.keys).to contain_exactly(:pattern, :third, :fourth)
    expect(chosen.values).to all(be_present)
  end

  it "leaves slots empty when the count is short" do
    chosen = described_class.for(history, count: 2)

    expect(chosen.values.compact.size).to eq(1)
  end

  it "prefers the slot whose kinds have gone longest unseen" do
    recent = history(*Array.new(12, %w[code_review pattern plan_review]))

    chosen = described_class.for(recent, count: 2)

    expect(chosen[:third]).to be_present
    expect(chosen[:pattern]).to be_nil
  end

  it "fills exactly two optional slots at count: 3" do
    chosen = described_class.for(history, count: 3)

    expect(chosen.values.compact.size).to eq(2)
  end

  it "derives its slot roster from ExerciseSection.slots rather than restating it" do
    expect(described_class::OPTIONAL_SLOTS).to eq(ExerciseSection.slots.keys - [ :code_review ])
  end

  # The regime this is designed for: every optional kind competing for one
  # slot, all of them maximally stale, so the tie-break does the work. The pool
  # is derived from the roster rather than counted, so adding an eighth kind
  # lengthens this run instead of leaving the new kind silently uncovered.
  it "drains the whole pool in pool-size days rather than repeating" do
    pool_size = (ExerciseSection.slots.values.flatten - [ ExerciseSection::CodeReview ]).size
    seen = []
    log  = []

    pool_size.times do
      chosen = described_class.for(history(*log.reverse), count: 2)
      kind   = chosen.values.compact.first
      seen << kind
      log << ([ "code_review" ] + chosen.values.compact.map(&:to_s))
    end

    expect(seen.uniq.size).to eq(pool_size)
  end

  def preferences(weights: {}, excluded: [])
    KindPreferences.new(weights: weights, excluded: excluded)
  end

  # Every third kind seen in the newest entry, so all four sit at staleness 1
  # and nothing is starved. Equal staleness is what leaves the multiplier as the
  # only thing separating them.
  def all_thirds_fresh
    history(%w[code_review architecture security_review challenge parsons_problem])
  end

  describe "user weights" do
    # Equal staleness gives four equal weights, so the roll's boundaries sit at
    # .25/.50/.75. Weighting challenge x4 makes the total 7 and moves its band to
    # .2857...8571 — so the SAME roll that used to land on security_review now
    # lands on challenge. Asserting both at one rand value pins the arithmetic,
    # not merely the direction.
    it "shifts the roll's boundaries by the stated multiplier" do
      allow(WeightedRoll).to receive(:rand).and_return(0.30)

      unweighted = described_class.send(:pick_kind, :third, all_thirds_fresh, KindPreferences.none)
      weighted   = described_class.send(:pick_kind, :third, all_thirds_fresh,
                                        preferences(weights: { "challenge" => 4.0 }))

      expect(unweighted).to eq(:security_review)
      expect(weighted).to eq(:challenge)
    end

    it "lands past a weighted kind's band on a high roll" do
      allow(WeightedRoll).to receive(:rand).and_return(0.90)

      chosen = described_class.send(:pick_kind, :third, all_thirds_fresh,
                                    preferences(weights: { "challenge" => 4.0 }))

      expect(chosen).to eq(:parsons_problem)
    end

    # The guarantee the whole feature is built around. Stubbing the roll to
    # raise proves the starvation branch returned before any weight was read —
    # structural, where asserting "it still shows up sometimes" would only be
    # statistical.
    it "cannot starve a kind, however low its weight" do
      recent = history(*Array.new(12, %w[code_review pattern architecture security_review parsons_problem]))
      allow(WeightedRoll).to receive(:pick).and_raise("the weighted roll must not be reached")

      chosen = described_class.send(:pick_kind, :third, recent,
                                    preferences(weights: { "challenge" => 0.25 }))

      expect(chosen).to eq(:challenge)
    end

    it "leaves slot filling untouched" do
      recent = history(*Array.new(12, %w[code_review pattern plan_review]))
      damped = preferences(weights: ExerciseSection.thirds.to_h { |kind| [ kind.key, 0.25 ] })

      filled = ->(prefs) { described_class.for(recent, count: 2, preferences: prefs).transform_values(&:present?) }

      expect(filled.call(damped)).to eq(filled.call(KindPreferences.none))
    end

    it "does not leak across the third and fourth tracks" do
      allow(WeightedRoll).to receive(:rand).and_return(0.30)
      recent = all_thirds_fresh

      with    = described_class.for(recent, count: 4, preferences: preferences(weights: { "plan_review" => 4.0 }))
      without = described_class.for(recent, count: 4, preferences: KindPreferences.none)

      expect(with[:third]).to eq(without[:third])
    end

    # KindPreferences.none is the kwarg's own default, so calling #for with and
    # without it can never diverge — pinned literal values are what makes an
    # untouched user's unweighted behaviour an assertion instead of a tautology.
    it "matches the unweighted rotation when nothing is stated" do
      allow(WeightedRoll).to receive(:rand).and_return(0.42)

      expect(described_class.for(all_thirds_fresh, count: 4))
        .to eq(pattern: :pattern, third: :security_review, fourth: :plan_review)
    end
  end

  describe "excluded kinds" do
    # Exclusion is applied before the starvation check, which is the whole
    # difference between it and a low weight: a starved kind is taken outright,
    # so anything that could not remove a kind from the pool entirely would be
    # overridden here.
    it "keeps an excluded kind out even when it is starved" do
      recent = history(*Array.new(12, %w[code_review pattern architecture security_review parsons_problem]))

      chosen = described_class.send(:pick_kind, :third, recent, preferences(excluded: [ "challenge" ]))

      expect(chosen).not_to eq(:challenge)
    end

    # slot_staleness is a max over the pool, so an excluded kind left in it would
    # pull its slot into a scarce spot on the strength of a kind that can never
    # fill it. Here architecture is the only stale third; excluding it hands the
    # slot to the fourth track.
    it "stops an excluded kind pulling its slot into a short day" do
      recent = history(*Array.new(12, %w[code_review pattern challenge security_review parsons_problem plan_review]))

      expect(described_class.for(recent, count: 2)[:third]).to be_present

      excluded = described_class.for(recent, count: 2, preferences: preferences(excluded: [ "architecture" ]))

      expect(excluded[:third]).to be_nil
      expect(excluded[:fourth]).to be_present
    end

    # User validation refuses this, so it can only arrive from a hand-edited
    # row. A slot with an empty pool would break slot ranking outright, and a
    # day that silently loses a section is worse than one ignoring an impossible
    # preference.
    it "ignores an exclusion that would empty a slot" do
      excluded = ExerciseSection.thirds.map(&:key)

      chosen = described_class.send(:pick_kind, :third, all_thirds_fresh, preferences(excluded: excluded))

      expect(ExerciseSection.thirds.map { |kind| kind.key.to_sym }).to include(chosen)
    end
  end
end
