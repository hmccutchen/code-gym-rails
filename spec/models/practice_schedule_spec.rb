require "rails_helper"

RSpec.describe PracticeSchedule do
  let(:daily) { DailyKinds::DEFAULT }
  let(:hosts) { DayHosts.new("ruby_rails", mode: :application_code) }
  let(:evidence) { { initial_reviewed_sets: 2, struggle: {}, pending: [] } }

  def plan(previous: nil, count: 2, setting: nil, pair: daily, facts: evidence, preferences: KindPreferences.none)
    described_class.plan(context: previous, count: count, setting: setting, daily: pair,
      preferences: preferences, evidence: facts, hosts: hosts, rotation_history: [], due: [], drills: [])
  end

  it "waits for two qualified reviewed sets, then replaces within the chosen capacity" do
    [ 0, 1 ].each do |reviewed|
      result = plan(facts: evidence.merge(initial_reviewed_sets: reviewed))
      expect(result.kinds).to eq(daily)
      expect(result.notes["phase"]).to be_nil
    end
    previous = nil
    phases = 6.times.map do
      result = plan(previous: previous)
      expect(result.kinds.size).to eq(2)
      previous = result.notes
      result.notes["phase"]
    end
    expect(phases).to eq([ 0, 1, 2, 0, 1, 2 ])
  end

  it "protects a lone struggling kind and alternates omissions when both struggle" do
    previous = nil
    omissions = []
    10.times do
      result = plan(previous: previous, facts: evidence.merge(struggle: daily.map(&:key).index_with { true }))
      previous = result.notes
      omissions << result.notes["omitted_kind"] if result.notes["omitted_kind"]
    end
    expect(omissions).to eq([ daily.last.key, daily.first.key, daily.last.key, daily.first.key ])
    daily.each do |protected_kind|
      expect(plan(facts: evidence.merge(struggle: { protected_kind.key => true })).kinds).to include(protected_kind)
    end
  end

  it "pauses phase for fixed settings, larger work and one newly selected pair" do
    previous = plan.notes
    fixed = plan(previous: previous, setting: 2)
    expect(fixed.kinds).to eq(daily)
    expect(fixed.notes["continuation"]["next_phase"]).to eq(1)
    larger = plan(previous: fixed.notes, count: 3)
    expect(larger.kinds.size).to eq(3)
    changed = plan(previous: larger.notes, pair: [ daily.first, ExerciseSection::Pattern ])
    expect(changed.kinds).to eq([ daily.first, ExerciseSection::Pattern ])
    expect(changed.notes["phase"]).to be_nil
    expect(changed.notes["continuation"]["next_phase"]).to eq(1)
  end

  it "rejects malformed or unknown notes instead of inventing a fresh cycle" do
    [ nil, [], { "version" => 99 }, plan.notes.deep_merge("continuation" => { "next_kind_index" => -1 }) ].each do |bad|
      expect { PracticeSchedule::Note.decode(bad) }.to raise_error(ArgumentError)
    end
    expect(PracticeSchedule::Note.decode({})).to eq({})
  end

  it "reuses a regenerated variety selection and never spends its continuation again" do
    original = plan
    replacement = described_class.plan(context: original.notes, count: DailyKinds::COUNT, setting: nil, daily: daily,
      preferences: KindPreferences.none, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [], replacing: true)
    expect(replacement.kinds).to eq(original.kinds)
    expect(replacement.notes.slice("sequence", "phase", "continuation")).to eq(original.notes.slice("sequence", "phase", "continuation"))
  end

  it "honors a new fixed pair on regeneration while preserving the original spent turn" do
    original = plan
    replacement = described_class.plan(context: original.notes, count: DailyKinds::COUNT, setting: DailyKinds::COUNT, daily: daily,
      preferences: KindPreferences.none, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [], replacing: true)
    expect(replacement.kinds).to eq(daily)
    expect(replacement.notes["continuation"]).to eq(original.notes["continuation"])
  end

  it "does not invent a variety turn when regenerating a legacy row" do
    result = described_class.plan(context: {}, count: DailyKinds::COUNT, setting: nil, daily: daily,
      preferences: KindPreferences.none, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [], replacing: true)
    expect(result.kinds).to eq(daily)
    expect(result.notes["phase"]).to be_nil
  end

  it "pauses through a fixed single section without inventing a new-pair acknowledgement" do
    first = plan
    single = described_class.plan(context: first.notes, count: 1, setting: 1, daily: daily.first(1), regular: daily,
      preferences: KindPreferences.none, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [])
    expect(single.notes["regular_kinds"]).to eq(daily.map(&:key))
    expect(single.notes["continuation"]["next_phase"]).to eq(first.notes["continuation"]["next_phase"])
    expect(plan(previous: single.notes).notes["phase"]).to eq(first.notes["continuation"]["next_phase"])
  end

  it "regenerates a formerly larger set within today's smaller capacity without taking the next variety turn" do
    original = plan(count: 3)
    replacement = described_class.plan(context: original.notes, count: DailyKinds::COUNT, setting: nil, daily: daily,
      preferences: KindPreferences.none, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [], replacing: true)
    expect(replacement.kinds).to eq(daily)
    expect(replacement.notes["continuation"]).to eq(original.notes["continuation"])
  end

  it "holds every fixed shape exactly while pausing the recurring pair cursor" do
    original = plan.notes
    (DailyKinds::FEWEST..DailyKinds::MOST).each do |count|
      held = (daily + [ ExerciseSection::Pattern, ExerciseSection.fourths.first ]).first(count)
      selected = described_class.plan(context: original, count: count, setting: count, daily: held, regular: daily,
        preferences: KindPreferences.none, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [])
      expect(selected.kinds).to eq(held)
      expect(selected.notes["phase"]).to be_nil
      expect(selected.notes["continuation"].slice("next_phase", "kind_order", "next_kind_index"))
        .to eq(original["continuation"].slice("next_phase", "kind_order", "next_kind_index"))
    end
  end

  it "keeps fourth siblings unavailable even when the daily fourth is omitted" do
    pair = [ ExerciseSection::CodeReview, ExerciseSection.fourths.first ]
    result = plan(pair: pair)
    expect(result.notes["omitted_kind"]).to eq(pair.last.key)
    expect(result.kinds & ExerciseSection.fourths).to be_empty
    expect(result.notes["continuation"]["kind_order"] & ExerciseSection.fourths.map(&:key)).to be_empty
  end

  it "consumes an empty-pool variety phase without overriding exclusions" do
    preferences = KindPreferences.new(weights: {}, excluded: ExerciseSection.optional_slots(daily: daily).values.flatten.map(&:key))
    result = plan(preferences: preferences)
    expect(result.kinds).to eq(daily)
    expect(result.notes["continuation"]).to include("next_phase" => 1, "kind_order" => [], "next_kind_index" => 0)
  end
end
