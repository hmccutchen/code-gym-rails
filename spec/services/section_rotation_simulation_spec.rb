require "rails_helper"

# The run behind docs/superpowers/specs/2026-10-16-daily-kind-swap-design.md section 6, on the real rotation.
RSpec.describe SectionRotation, "over every reachable pair" do
  let(:days) { 160 }
  let(:warmup) { 30 }
  let(:seed) { 1 }

  def reachable_pairs
    ExerciseSection.all.combination(2).reject { |pair| pair.count(&:fourth?) > 1 }
  end

  def entry(keys) = ExerciseHistoryEntry.new(section_keys: keys, delivered_section_keys: keys, answered: keys.size, dropped: 0)

  def simulate(daily, count, seed)
    previous = srand(seed)
    history  = []
    seen_on = {}
    longest = Hash.new(0)

    days.times do |day|
      chosen = described_class.for(history, count: count, daily: daily)
      keys   = daily.map(&:key) + chosen.values.compact.map(&:to_s)
      history.unshift(entry(keys))
      history.pop if history.size > described_class::LOOKBACK
      keys.each do |key|
        longest[key] = [ longest[key], day - seen_on[key] ].max if seen_on[key] && day >= warmup
        seen_on[key] = day
      end
    end
    seen_on.each { |key, last| longest[key] = [ longest[key], days - last ].max }
    [ longest, seen_on.keys ]
  ensure
    srand(previous)
  end

  it "holds the pair count at 42" do
    expect(reachable_pairs.size).to eq(42)
  end

  [ 3, 4 ].each do |count|
    it "keeps every optional kind within the starvation bound, and a daily fourth's siblings out, at #{count} sections" do
      bound = described_class::STARVATION_LIMIT + 1

      reachable_pairs.each do |daily|
        optional = ExerciseSection.optional_slots(daily: daily).values.flatten.map(&:key)
        siblings = daily.any?(&:fourth?) ? (ExerciseSection.fourths - daily).map(&:key) : []
        longest, seen = simulate(daily, count, seed)

        expect(optional - seen).to be_empty, "#{daily.map(&:key)} at #{count}: never saw #{optional - seen}"
        expect(longest.slice(*optional).values.max).to be <= bound, "#{daily.map(&:key)} at #{count}: #{longest.slice(*optional)}"
        expect(seen & siblings).to be_empty, "#{daily.map(&:key)} at #{count} showed #{seen & siblings}"
      end
    end
  end
end
