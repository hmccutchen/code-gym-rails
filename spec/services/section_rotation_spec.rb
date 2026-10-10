require "rails_helper"

RSpec.describe SectionRotation do
  def history(*key_sets)
    key_sets.map do |keys|
      ExerciseHistoryEntry.new(section_keys: keys, delivered_section_keys: keys, answered: keys.size, dropped: 0)
    end
  end

  it "fills two of the three optional slots at full size" do
    chosen = described_class.for(history, count: 4)

    expect(chosen.keys).to contain_exactly(:pattern, :third, :fourth)
    expect(chosen.values.compact.size).to eq(2)
  end

  it "fills no optional slot at the floor, which the fixed kinds already make up" do
    chosen = described_class.for(history, count: 2)

    expect(chosen.values.compact).to be_empty
  end

  it "prefers the slot whose kinds have gone longest unseen" do
    recent = history(*Array.new(12, %w[code_review design_comparison pattern plan_review]))

    chosen = described_class.for(recent, count: 3)

    expect(chosen[:third]).to be_present
    expect(chosen[:pattern]).to be_nil
  end

  it "fills exactly one optional slot at count: 3" do
    chosen = described_class.for(history, count: 3)

    expect(chosen.values.compact.size).to eq(1)
  end

  it "derives its slot roster from ExerciseSection.slots rather than restating it" do
    fixed_slots = ExerciseSection.fixed.map { |kind| kind.key.to_sym }

    expect(described_class::OPTIONAL_SLOTS).to eq(ExerciseSection.slots.keys - fixed_slots)
    expect(described_class::OPTIONAL_SLOTS).to eq(%i[pattern third fourth])
  end

  it "counts one mandatory slot per fixed kind" do
    expect(described_class::MANDATORY_SLOT_COUNT).to eq(ExerciseSection.fixed.size)
    expect(described_class::MANDATORY_SLOT_COUNT).to eq(2)
  end

  # The pool derives from the roster, so a new kind lengthens this run instead of going uncovered.
  it "drains the whole pool in pool-size days rather than repeating" do
    pool_size = (ExerciseSection.slots.values.flatten - ExerciseSection.fixed).size
    seen = []
    log  = []

    pool_size.times do
      chosen = described_class.for(history(*log.reverse), count: 3)
      kind   = chosen.values.compact.first
      seen << kind
      log << (ExerciseSection.fixed.map(&:key) + chosen.values.compact.map(&:to_s))
    end

    expect(seen.uniq.size).to eq(pool_size)
  end

  def preferences(weights: {}, excluded: [])
    KindPreferences.new(weights: weights, excluded: excluded)
  end

  # Equal staleness leaves the multiplier as the only thing separating the thirds.
  def all_thirds_fresh
    history(%w[code_review architecture security_review challenge parsons_problem])
  end

  describe "user weights" do
    # Challenge x4 moves its band to .2857-.8571, so the same roll lands on challenge instead.
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

    # A raising roll proves the starvation branch returned before any weight was read.
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

      filled = ->(prefs) { described_class.for(recent, count: 3, preferences: prefs).transform_values(&:present?) }

      expect(filled.call(damped)).to eq(filled.call(KindPreferences.none))
    end

    it "does not leak across the third and fourth tracks" do
      allow(WeightedRoll).to receive(:rand).and_return(0.30)
      recent = history(%w[code_review design_comparison pattern],
                       %w[code_review architecture security_review challenge parsons_problem plan_review ambiguity_hunt])

      with    = described_class.for(recent, count: 4, preferences: preferences(weights: { "plan_review" => 4.0 }))
      without = described_class.for(recent, count: 4, preferences: KindPreferences.none)

      expect(with[:third]).to eq(without[:third])
    end

    # Pinned values make the untouched-user case an assertion; the third slot is stalest here.
    it "matches the unweighted rotation when nothing is stated" do
      allow(WeightedRoll).to receive(:rand).and_return(0.42)
      recent = history(%w[code_review design_comparison pattern plan_review ambiguity_hunt pseudocode_to_code],
                       %w[code_review design_comparison architecture security_review challenge parsons_problem])

      expect(described_class.for(recent, count: 3))
        .to eq(pattern: nil, third: :security_review, fourth: nil)
    end
  end

  describe "excluded kinds" do
    # Exclusion runs before the starvation check, which takes a starved kind outright.
    it "keeps an excluded kind out even when it is starved" do
      recent = history(*Array.new(12, %w[code_review pattern architecture security_review parsons_problem]))

      chosen = described_class.send(:pick_kind, :third, recent, preferences(excluded: [ "challenge" ]))

      expect(chosen).not_to eq(:challenge)
    end

    # slot_staleness is a max over the pool, so an excluded kind would still pull its slot forward.
    it "stops an excluded kind pulling its slot into a short day" do
      recent = history(*Array.new(12, %w[code_review pattern challenge security_review parsons_problem plan_review]))

      expect(described_class.for(recent, count: 3)[:third]).to be_present

      excluded = described_class.for(recent, count: 3, preferences: preferences(excluded: [ "architecture" ]))

      expect(excluded[:third]).to be_nil
      expect(excluded[:fourth]).to be_present
    end

    # Only a hand-edited row reaches this; an empty slot pool would break slot ranking.
    it "ignores an exclusion that would empty a slot" do
      excluded = ExerciseSection.thirds.map(&:key)

      chosen = described_class.send(:pick_kind, :third, all_thirds_fresh, preferences(excluded: excluded))

      expect(ExerciseSection.thirds.map { |kind| kind.key.to_sym }).to include(chosen)
    end
  end
end
