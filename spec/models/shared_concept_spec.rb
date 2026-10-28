require "rails_helper"

RSpec.describe SharedConcept do
  let(:hosts) { DayHosts.new("ruby_rails", mode: :application_code) }
  let(:fixed) { DailyKinds::DEFAULT }

  def entry(concept, tier: "standard", drilled: nil)
    { concept: concept, bucket: "ruby_rails", tier: tier, drilled: drilled }.compact
  end

  def pick(list, kinds:, due_checks: [])
    described_class.pick(list, due_checks, hosts, kinds: kinds, daily: fixed)
  end

  it "takes the first reduced entry every fixed section can tag, drilled or not, when the rest fit elsewhere" do
    list = [ entry("memoization"), entry("transaction_safety", tier: "reduced"), entry("n_plus_one", tier: "reduced", drilled: true) ]

    expect(pick(list, kinds: fixed + [ ExerciseSection::Pattern, ExerciseSection::Challenge ]))
      .to eq(entry("n_plus_one", tier: "reduced", drilled: true))
  end

  it "takes nothing from a list with no reduced entry" do
    expect(pick([ entry("n_plus_one") ], kinds: fixed + [ ExerciseSection::Pattern ])).to be_nil
  end

  it "takes nothing for a pair holding a fourth kind, which cannot tag a language concept" do
    daily = [ ExerciseSection::CodeReview, ExerciseSection::PlanReview ]
    list  = [ entry("n_plus_one", tier: "reduced") ]

    expect(described_class.pick(list, [], hosts, kinds: daily + [ ExerciseSection::Pattern ], daily: daily)).to be_nil
  end

  it "takes nothing for a day with no pair, since one section shares a concept with nothing" do
    list = [ entry("n_plus_one", tier: "reduced") ]

    expect(described_class.pick(list, [], hosts, kinds: [ ExerciseSection::CodeReview ], daily: [])).to be_nil
  end

  it "takes nothing when the day left no host free" do
    expect(pick([ entry("n_plus_one", tier: "reduced"), entry("memoization") ], kinds: fixed)).to be_nil
  end

  # Architecture cannot tag a Ruby concept, so counting free sections alone would have paired.
  it "takes nothing when another entry would lose its only host" do
    list = [ entry("n_plus_one", tier: "reduced"), entry("transaction_safety") ]

    expect(pick(list, kinds: fixed + [ ExerciseSection::Architecture ])).to be_nil
  end

  it "takes nothing when a due check would lose its only host" do
    check = ConceptMastery.new(concept: "memoization", language: "ruby_rails")

    expect(pick([ entry("n_plus_one", tier: "reduced") ], kinds: fixed, due_checks: [ check ])).to be_nil
    expect(pick([ entry("n_plus_one", tier: "reduced") ], kinds: fixed + [ ExerciseSection::Pattern ], due_checks: [ check ]))
      .to eq(entry("n_plus_one", tier: "reduced"))
  end
end
