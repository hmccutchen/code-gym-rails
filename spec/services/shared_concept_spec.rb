require "rails_helper"

RSpec.describe SharedConcept do
  let(:hosts) { DayHosts.new("ruby_rails", mode: :application_code) }

  def entry(concept, tier: "standard", drilled: nil)
    { concept: concept, bucket: "ruby_rails", tier: tier, drilled: drilled }.compact
  end

  describe ".pick" do
    it "takes the first reduced entry both fixed sections can tag, drilled or not" do
      list = [ entry("memoization"), entry("transaction_safety", tier: "reduced"), entry("n_plus_one", tier: "reduced", drilled: true) ]

      expect(described_class.pick(list, hosts)).to eq(entry("n_plus_one", tier: "reduced", drilled: true))
    end

    it "takes nothing from a list with no reduced entry" do
      expect(described_class.pick([ entry("n_plus_one") ], hosts)).to be_nil
    end
  end

  describe ".fit" do
    let(:shared) { entry("n_plus_one", tier: "reduced") }

    it "gives the shared entry one host more than its place in the list" do
      list = [ entry("memoization"), shared, entry("service_objects") ]

      expect(described_class.fit(list, shared, 3)).to eq([ [ entry("memoization"), shared ], shared ])
      expect(described_class.hosts_taken([ entry("memoization"), shared ], shared)).to eq(3)
    end

    it "keeps the concept as ordinary reinforcement when one host is left" do
      expect(described_class.fit([ shared, entry("memoization") ], shared, 1)).to eq([ [ shared ], nil ])
    end

    it "only truncates when nothing is shared" do
      expect(described_class.fit([ entry("a"), entry("b") ], nil, 1)).to eq([ [ entry("a") ], nil ])
    end
  end
end
