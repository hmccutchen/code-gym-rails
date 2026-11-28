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

  it "services an explicitly requested kind without advancing the automatic sequence" do
    previous = plan.notes
    turn = described_class.plan(context: previous, daily: daily, preferences: preferences,
      evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [], requested_kind: "challenge")
    selected = PracticeSchedule.single_plan(context: previous, daily: daily, preferences: preferences,
      evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [], turn: turn)

    expect(selected.kinds).to eq([ ExerciseSection::Challenge ])
    expect(selected.notes.fetch("sequence")).to eq(previous.fetch("sequence"))
    expect(selected.notes.dig("continuation", "kind_service", "ruby_rails", "challenge")).to eq(previous.fetch("sequence"))
    expect(previous.fetch("selected_kinds")).not_to eq([])
  end

  it "assigns and records useful retention service for the requested kind" do
    previous = plan.notes
    due = [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 3 } ]
    options = { context: previous, daily: daily, preferences: preferences, evidence: evidence,
      hosts: hosts, rotation_history: [], due: due, drills: [] }
    turn = described_class.plan(**options, requested_kind: "pattern")
    selected = PracticeSchedule.single_plan(**options, turn: turn)

    expect(selected.assignments.fetch("pattern")).to include(concept: "memoization", reason: "retention")
    expect(selected.notes.dig("continuation", "service", "ruby_rails", "pattern", "last_lane")).to eq("maintenance")
    expect(selected.notes.fetch("sequence")).to eq(previous.fetch("sequence"))
  end

  it "rejects a requested kind excluded from the available pool" do
    expect {
      described_class.plan(context: {}, daily: daily, preferences: KindPreferences.new(weights: {}, excluded: [ "challenge" ]),
        evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: [], requested_kind: "challenge")
    }.to raise_error(ArgumentError, /eligible/)
  end

  it "serves every eligible kind before repeating despite a persistent struggling request" do
    facts = evidence.merge(pending: [ { kind: "pattern", concept: "memoization", bucket: "ruby_rails", mode: "support" } ])
    previous = {}
    pool = ExerciseSection.pickable(daily: daily)
    turns = (pool.size * 3).times.map do
      selected = plan(previous: previous, facts: facts)
      expect(selected.kinds.size).to eq(1)
      expect(selected.notes).to include("version" => 3, "policy" => 2)
      previous = selected.notes
      selected.kinds.sole
    end
    turns.each_slice(pool.size) { |round| expect(round).to match_array(pool) }
  end

  { application_code: ExerciseSection::CodeReview, bug_hunt: ExerciseSection::Pattern }.each do |mode, expected|
    it "prioritizes struggle only when its kind can host core practice in #{mode}" do
      facts = evidence.merge(struggle: { "code_review" => true })
      selected = plan(facts: facts, pair: [ ExerciseSection::CodeReview, ExerciseSection::Pattern ],
        host: DayHosts.new("ruby_rails", mode: mode),
        due: [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 3 } ])

      expect(selected.kinds).to eq([ expected ])
      expect(selected.assignments.fetch(expected.key)).to include(concept: "memoization", reason: "retention")
    end
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
    expect(selected.notes.fetch("continuation").fetch("kind_service").fetch("ruby_rails").keys & %w[ambiguity_hunt pseudocode_to_code]).to be_empty
  end

  it "retains valid prior practice service when translating format one" do
    legacy = PracticeSchedule.plan(context: nil, count: 2, setting: 2, daily: daily,
      preferences: preferences, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: []).notes
    legacy["continuation"]["service"] = { "pattern" => { "last_lane" => "maintenance", "last_maintenance" => "retention", "concepts" => [] } }
    selected = plan(previous: legacy)
    expect(selected.notes["sequence"]).to eq(legacy["sequence"] + 1)
    expect(selected.notes.dig("continuation", "service", "ruby_rails", "pattern")).to eq({ "last_lane" => nil, "last_maintenance" => nil, "concepts" => [] })
    expect(selected.notes["continuation"].keys).to match_array(%w[kind_service service])
  end
  it "does not credit dropped historical sections or mutate captured notes" do
    history = [ ExerciseHistoryEntry.new(section_keys: %w[code_review pattern], delivered_section_keys: %w[code_review], dropped: %w[pattern]) ]
    selected = plan(history: history)
    expect(selected.notes.dig("continuation", "kind_service", "ruby_rails", "code_review")).to eq(1)
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

  it "translates a format-one replacement without advancing sequence or guessing lane language" do
    legacy = PracticeSchedule.plan(context: nil, count: 2, setting: 2, daily: daily,
      preferences: preferences, evidence: evidence, hosts: hosts, rotation_history: [], due: [], drills: []).notes
    legacy["continuation"]["service"] = { "pattern" => { "last_lane" => "maintenance", "last_maintenance" => "drill", "concepts" => [] } }

    selected = plan(previous: legacy, replacing: true)

    expect(selected.kinds.size).to eq(1)
    expect(selected.notes["version"]).to eq(3)
    expect(selected.notes["sequence"]).to eq(legacy["sequence"])
    expect(selected.notes.dig("continuation", "service", "ruby_rails", "pattern")).to eq({ "last_lane" => nil, "last_maintenance" => nil, "concepts" => [] })
    expect(selected.notes.dig("continuation", "kind_service")).to eq({ "ruby_rails" => {} })
  end

  it "gives a weekend bug hunt no core retention or practice assignment" do
    host = DayHosts.new("ruby_rails", mode: ExerciseSection::CodeReview::BugHunt::MODE)
    prefs = KindPreferences.new(weights: {}, excluded: ExerciseSection.keys - %w[code_review])
    facts = evidence.merge(pending: [ { kind: "code_review", concept: "memoization", bucket: "ruby_rails", mode: "support" } ])
    selected = plan(pair: [ ExerciseSection::CodeReview ], prefs: prefs, facts: facts, host: host,
      due: [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 3 } ])

    expect(selected.kinds).to eq([ ExerciseSection::CodeReview ])
    expect(selected.assignments).to eq({})
    expect(selected.notes.dig("continuation", "service", "ruby_rails")).to eq({})
  end

  it "assigns only the current language bucket's hostable obligation" do
    host = DayHosts.new("javascript", mode: :application_code)
    prefs = KindPreferences.new(weights: {}, excluded: ExerciseSection.keys - %w[code_review])
    facts = evidence.merge(pending: [ { kind: "code_review", concept: "closures", bucket: "javascript", mode: "support" } ])
    selected = plan(pair: [ ExerciseSection::CodeReview ], prefs: prefs, facts: facts, host: host,
      due: [ { concept: "memoization", bucket: "ruby_rails", overdue_ratio: 3 } ])

    expect(selected.assignments.fetch("code_review")).to include(concept: "closures", bucket: "javascript", reason: "support")
  end

  it "preserves both languages when switching and regenerating a format-three set" do
    ruby = plan
    javascript = plan(previous: ruby.notes, host: DayHosts.new("javascript", mode: :application_code))
    again = plan(previous: javascript.notes)
    expect(javascript.notes.dig("continuation", "kind_service", "ruby_rails")).to eq(ruby.notes.dig("continuation", "kind_service", "ruby_rails"))
    expect(again.notes.dig("continuation", "kind_service", "javascript")).to eq(javascript.notes.dig("continuation", "kind_service", "javascript"))
    replacement = plan(previous: javascript.notes, host: DayHosts.new("javascript", mode: :application_code), replacing: true)
    expect(replacement.notes.slice("sequence", "continuation")).to eq(javascript.notes.slice("sequence", "continuation"))
  end

  it "translates format two without assigning global kind or lane service to a language" do
    legacy = { "version" => 2, "policy" => 2, "sequence" => 4, "initial_ready" => true,
      "regular_kinds" => daily.map(&:key), "selected_kinds" => [ "code_review" ], "assignments" => {},
      "continuation" => { "kind_service" => { "code_review" => 4 }, "service" => {
        "code_review" => { "last_lane" => "practice", "last_maintenance" => "retention", "concepts" => [
          { "concept" => "memoization", "bucket" => "ruby_rails", "sequence" => 2 },
          { "concept" => "closures", "bucket" => "javascript", "sequence" => 4 }
        ] },
        "architecture" => { "last_lane" => "practice", "last_maintenance" => nil, "concepts" => [
          { "concept" => "sync_vs_async", "bucket" => "architecture", "sequence" => 3 }
        ] }
      } } }
    translated = plan(previous: legacy, replacing: true).notes
    expect(translated["sequence"]).to eq(4)
    expect(translated.dig("continuation", "kind_service")).to eq("ruby_rails" => {})
    %w[ruby_rails javascript].each do |language|
      service = translated.dig("continuation", "service", language)
      expect(service.fetch("code_review")).to include("last_lane" => nil, "last_maintenance" => nil)
      expect(service.dig("code_review", "concepts").pluck("bucket")).to eq([ language ])
      expect(service.dig("architecture", "concepts")).to eq(legacy.dig("continuation", "service", "architecture", "concepts"))
    end
    expect(legacy.dig("continuation", "service", "code_review", "last_lane")).to eq("practice")
  end

  context "when supplementary delivery has not served a hostable need" do
    let(:pool) { preferences.offered(daily: daily) }
    let(:prior) do
      { "version" => 3, "policy" => 2, "sequence" => 100, "initial_ready" => true,
        "regular_kinds" => daily.map(&:key), "selected_kinds" => [ "code_review" ], "assignments" => {},
        "continuation" => { "kind_service" => { "ruby_rails" => pool.each_with_index.to_h { |kind, index| [ kind.key, 100 - index ] } },
          "service" => {} } }
    end
    let(:need) { { kind: "code_review", concept: "memoization", bucket: "ruby_rails", mode: "support" } }
    let(:recent) do
      pool.each_with_index.map { |kind, index| delivery(kind.key, sequence: 100 - index, host: kind != ExerciseSection::CodeReview) }
    end
    let(:last_host) { delivery("code_review", sequence: 50) }

    def delivery(key, sequence: nil, host: true)
      ExerciseHistoryEntry.new(section_keys: [ key ], delivered_section_keys: [ key ], dropped: 0,
        planning_host_keys: host ? [ key ] : [], schedule_sequence: sequence)
    end

    [ :pending, :struggle, :reinforcement, :retention, :drill ].each do |reason|
      it "uses older host service for a #{reason} need after one eligible-pool worth of delivered days" do
        facts = evidence.merge(pending: reason == :pending ? [ need ] : [],
          struggle: reason == :struggle ? { "code_review" => true } : {},
          reinforcement: reason == :reinforcement ? [ need ] : [])
        selected = plan(previous: prior, facts: facts, history: recent + [ last_host ],
          due: reason == :retention ? [ need ] : [], drills: reason == :drill ? [ need ] : [])

        expect(selected.kinds).to eq([ ExerciseSection::CodeReview ])
        expect(selected.notes.dig("continuation", "kind_service", "ruby_rails", "code_review")).to eq(101)
      end
    end

    it "does not promote the need one delivery before the pool-size boundary" do
      selected = plan(previous: prior, facts: evidence.merge(pending: [ need ]), history: recent.take(pool.size - 1) + [ last_host ])
      expect(selected.kinds).to eq([ pool.last ])
    end

    it "does not count a fully dropped set toward successful deliveries" do
      dropped = ExerciseHistoryEntry.new(section_keys: [ "code_review" ], delivered_section_keys: [], dropped: 1,
        planning_host_keys: [], schedule_sequence: 99)
      history = recent.take(pool.size - 1) + [ dropped, last_host ]
      expect(plan(previous: prior, facts: evidence.merge(pending: [ need ]), history: history).kinds).to eq([ pool.last ])
    end

    it "uses a conservative debt floor for an absent or unversioned host delivery" do
      [ recent, recent + [ delivery("code_review") ] ].each do |history|
        expect(plan(previous: prior, facts: evidence.merge(pending: [ need ]), history: history).kinds).to eq([ ExerciseSection::CodeReview ])
      end
    end

    it "does not promote an unhostable need or a kind without a current need" do
      [ { facts: evidence }, { facts: evidence.merge(pending: [ need ]), host: DayHosts.new("ruby_rails", mode: :bug_hunt) } ].each do |options|
        expect(plan(previous: prior, history: recent + [ last_host ], **options).kinds).to eq([ pool.last ])
      end
    end

    it "resets host debt after the actual host delivery and leaves proposals uncredited until committed" do
      facts = evidence.merge(pending: [ need ])
      history = recent + [ last_host ]
      selected = plan(previous: prior, facts: facts, history: history)
      expect(plan(previous: prior, facts: facts, history: history).kinds).to eq(selected.kinds)
      expect(prior.dig("continuation", "kind_service", "ruby_rails", "code_review")).to eq(100)
      expect(history).to eq(recent + [ last_host ])

      committed = [ delivery("code_review", sequence: selected.notes.fetch("sequence")) ] + history
      expect(plan(previous: selected.notes, facts: facts, history: committed).kinds).to eq([ pool.last ])
      replacement = plan(previous: selected.notes, facts: facts, history: history, replacing: true)
      expect(replacement.notes.slice("sequence", "continuation")).to eq(selected.notes.slice("sequence", "continuation"))
    end
  end
end
