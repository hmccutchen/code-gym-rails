require "rails_helper"

RSpec.describe PracticeSchedule::SingleSlot do
  let(:daily) { DailyKinds::DEFAULT }
  let(:hosts) { DayHosts.new("ruby_rails", mode: :application_code) }
  let(:evidence) { { initial_reviewed_sets: 0, struggle: {}, pending: [] } }
  let(:preferences) { KindPreferences.none }

  def plan(previous: {}, facts: evidence, due: [], drills: [], history: [], replacing: false, pair: daily, prefs: preferences, host: hosts)
    PracticeSchedule.single_plan(context: previous, daily: pair, preferences: prefs,
      evidence: facts, hosts: host, rotation_history: history, due: due, drills: drills, replacing: replacing)
  end

  it "serves every eligible kind before repeating despite a persistent struggling request" do
    facts = evidence.merge(pending: [ { kind: "pattern", concept: "memoization", bucket: "ruby_rails", mode: "support" } ])
    previous = {}
    pool = ExerciseSection.pickable(daily: daily)
    turns = (pool.size * 3).times.map do
      selected = plan(previous: previous, facts: facts)
      expect(selected.kinds.size).to eq(1)
      expect(selected.notes).to include("version" => 2, "policy" => 2)
      previous = selected.notes
      selected.kinds.sole
    end
    turns.each_slice(pool.size) { |round| expect(round).to match_array(pool) }
  end

  it "alternates contested practice and maintenance without losing retention or drills" do
    prefs = KindPreferences.new(weights: {}, excluded: ExerciseSection.keys - %w[pattern])
    facts = evidence.merge(pending: [ { kind: "pattern", concept: "memoization", bucket: "ruby_rails", mode: "support" } ])
    previous = {}
    reasons = 8.times.map do
      selected = plan(previous: previous, facts: facts, prefs: prefs, pair: [ ExerciseSection::Pattern ],
        due: [ { concept: "n_plus_one", bucket: "ruby_rails", overdue_ratio: 3 } ],
        drills: [ { concept: "service_objects", bucket: "ruby_rails" } ])
      previous = selected.notes
      selected.assignments.fetch("pattern").fetch(:reason)
    end
    expect(reasons).to eq(%w[support retention support drill support retention support drill])
  end

  it "uses delivered history before choosing another recent kind" do
    history = ExerciseSection.all.map { |kind| ExerciseHistoryEntry.new(section_keys: [ kind.key ], delivered_section_keys: [ kind.key ], dropped: []) }
    selected = plan(history: history)
    expect(selected.kinds).to eq([ ExerciseSection.all.last ])
  end

  it "preserves continuation and sequence on regeneration" do
    original = plan
    replacement = plan(previous: original.notes, replacing: true)
    expect(replacement.kinds).to eq(original.kinds)
    expect(replacement.notes.slice("sequence", "continuation")).to eq(original.notes.slice("sequence", "continuation"))
  end

  it "changes an excluded regenerated kind without spending another turn" do
    original = plan
    prefs = KindPreferences.new(weights: {}, excluded: original.kinds.map(&:key))
    replacement = plan(previous: original.notes, replacing: true, prefs: prefs, pair: [ ExerciseSection::Pattern, ExerciseSection::Challenge ])
    expect(replacement.kinds & original.kinds).to be_empty
    expect(replacement.notes.slice("sequence", "continuation")).to eq(original.notes.slice("sequence", "continuation"))
  end

  it "keeps fourth siblings unavailable when a fourth is a regular preference" do
    selected = plan(pair: [ ExerciseSection::CodeReview, ExerciseSection::PlanReview ])
    expect(selected.notes.fetch("continuation").fetch("kind_service").keys & %w[ambiguity_hunt pseudocode_to_code]).to be_empty
  end

  it "retains valid prior practice service when translating format one" do
    legacy = PracticeSchedule.plan(context: nil, count: 2, setting: 2, daily: daily,
      preferences: preferences, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: []).notes
    legacy["continuation"]["service"] = { "pattern" => { "last_lane" => "maintenance", "last_maintenance" => "retention", "concepts" => [] } }
    selected = plan(previous: legacy)
    expect(selected.notes["sequence"]).to eq(legacy["sequence"] + 1)
    expect(selected.notes.dig("continuation", "service", "pattern")).to eq(legacy.dig("continuation", "service", "pattern"))
    expect(selected.notes["continuation"].keys).to match_array(%w[kind_service service])
  end
  it "does not credit dropped historical sections or mutate captured notes" do
    history = [ ExerciseHistoryEntry.new(section_keys: %w[code_review pattern], delivered_section_keys: %w[code_review], dropped: %w[pattern]) ]
    selected = plan(history: history)
    expect(selected.notes.dig("continuation", "kind_service", "code_review")).to eq(1)
    previous = selected.notes.deep_dup
    plan(previous: selected.notes)
    expect(selected.notes).to eq(previous)
  end

  it "ignores hidden stored weights for regular preferences" do
    prefs = KindPreferences.new(weights: { daily.last.key => 4.0 }, excluded: [])
    expect(WeightedRoll).to receive(:pick).with({ daily.first => 1.0, daily.last => 1.0 }).and_return(daily.last)
    expect(plan(prefs: prefs).kinds).to eq([ daily.last ])
  end

  it "does not assign an unhostable retention obligation or change its input" do
    due = [ { concept: "sync_vs_async", bucket: "architecture", overdue_ratio: 10 } ]
    prefs = KindPreferences.new(weights: {}, excluded: ExerciseSection.keys - daily.map(&:key))
    selected = plan(due: due, prefs: prefs)
    expect(selected.assignments).to eq({})
    expect(due).to eq([ { concept: "sync_vs_async", bucket: "architecture", overdue_ratio: 10 } ])
  end

  it "keeps a regular preference eligible despite its hidden historical exclusion" do
    prefs = KindPreferences.new(weights: {}, excluded: ExerciseSection.keys)
    first = plan(prefs: prefs)
    second = plan(previous: first.notes, prefs: prefs)
    expect(first.kinds + second.kinds).to match_array(daily)
  end

  it "weights optional ties after committed kind recency" do
    optional = [ ExerciseSection::Architecture, ExerciseSection::SecurityReview ]
    prefs = KindPreferences.new(weights: { optional.first.key => 4.0 }, excluded: ExerciseSection.keys - (daily + optional).map(&:key))
    history = [ ExerciseHistoryEntry.new(section_keys: daily.map(&:key), delivered_section_keys: daily.map(&:key), dropped: []) ]
    expect(WeightedRoll).to receive(:pick).with({ optional.first => 4.0, optional.last => 1.0 }).and_return(optional.last)
    expect(plan(prefs: prefs, history: history).kinds).to eq([ optional.last ])
  end

  it "translates a format-one replacement without advancing sequence or assignment service" do
    legacy = PracticeSchedule.plan(context: nil, count: 2, setting: 2, daily: daily,
      preferences: preferences, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: []).notes
    legacy["continuation"]["service"] = { "pattern" => { "last_lane" => "maintenance", "last_maintenance" => "drill", "concepts" => [] } }

    selected = plan(previous: legacy, replacing: true)

    expect(selected.kinds.size).to eq(1)
    expect(selected.notes["version"]).to eq(2)
    expect(selected.notes["sequence"]).to eq(legacy["sequence"])
    expect(selected.notes.dig("continuation", "service")).to eq(legacy.dig("continuation", "service"))
    expect(selected.notes.dig("continuation", "kind_service")).to eq({})
  end

  it "gives a weekend bug hunt no core retention or practice assignment" do
    host = DayHosts.new("ruby_rails", mode: ExerciseSection::CodeReview::BugHunt::MODE)
    prefs = KindPreferences.new(weights: {}, excluded: ExerciseSection.keys - %w[code_review])
    facts = evidence.merge(pending: [ { kind: "code_review", concept: "memoization", bucket: "ruby_rails", mode: "support" } ])
    selected = plan(pair: [ ExerciseSection::CodeReview ], prefs: prefs, facts: facts, host: host,
      due: [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 3 } ])

    expect(selected.kinds).to eq([ ExerciseSection::CodeReview ])
    expect(selected.assignments).to eq({})
    expect(selected.notes.dig("continuation", "service")).to eq({})
  end

  it "assigns only the current language bucket's hostable obligation" do
    host = DayHosts.new("javascript", mode: :application_code)
    prefs = KindPreferences.new(weights: {}, excluded: ExerciseSection.keys - %w[code_review])
    facts = evidence.merge(pending: [ { kind: "code_review", concept: "closures", bucket: "javascript", mode: "support" } ])
    selected = plan(pair: [ ExerciseSection::CodeReview ], prefs: prefs, facts: facts, host: host,
      due: [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 3 } ])

    expect(selected.assignments.fetch("code_review")).to include(concept: "closures", bucket: "javascript", reason: "support")
  end
end
