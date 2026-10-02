require "rails_helper"

RSpec.describe SharedConcept do
  let(:hosts) { DayHosts.new("ruby_rails", mode: :application_code) }

  def entry(concept, tier: "standard", drilled: nil)
    { concept: concept, bucket: "ruby_rails", tier: tier, drilled: drilled }.compact
  end

  it "takes the first reduced entry every fixed section can tag, drilled or not" do
    list = [ entry("memoization"), entry("transaction_safety", tier: "reduced"), entry("n_plus_one", tier: "reduced", drilled: true) ]

    expect(described_class.pick(list, hosts, spare: 1)).to eq(entry("n_plus_one", tier: "reduced", drilled: true))
  end

  it "takes nothing from a list with no reduced entry" do
    expect(described_class.pick([ entry("n_plus_one") ], hosts, spare: 1)).to be_nil
  end

  it "takes nothing when the day left no host free" do
    expect(described_class.pick([ entry("n_plus_one", tier: "reduced") ], hosts, spare: 0)).to be_nil
  end
end
