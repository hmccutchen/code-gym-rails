require "rails_helper"

RSpec.describe SectionRotation do
  def history(*key_sets)
    key_sets.map { |keys| ExerciseHistoryEntry.new(section_keys: keys, answered: keys.size) }
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

  # The regime this is designed for: seven kinds competing for one slot, all
  # of them maximally stale, so the tie-break does the work.
  it "drains the whole pool in pool-size days rather than repeating" do
    seen = []
    log  = []

    7.times do
      chosen = described_class.for(history(*log.reverse), count: 2)
      kind   = chosen.values.compact.first
      seen << kind
      log << ([ "code_review" ] + chosen.values.compact.map(&:to_s))
    end

    expect(seen.uniq.size).to eq(7)
  end
end
