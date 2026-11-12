require "rails_helper"

RSpec.describe KeyHold do
  it "counts a rejected key and an account out of credit, and names them once" do
    expect(described_class::KINDS).to eq(%w[bad_key out_of_credit])
    expect(ProviderFailure::KINDS).to include(*described_class::KINDS)
  end

  it "holds after two failures in a row" do
    expect(described_class::AFTER).to eq(2)
  end

  describe ".counts?" do
    it "is true for each kind on the list, given as a string or a symbol" do
      expect(described_class::KINDS.map { |kind| described_class.counts?(kind) }).to all(be(true))
      expect(described_class.counts?(:bad_key)).to be(true)
    end

    it "is false for every other failure kind, and for none" do
      others = ProviderFailure::KINDS - described_class::KINDS

      expect(others).not_to be_empty
      expect(others.map { |kind| described_class.counts?(kind) }).to all(be(false))
      expect(described_class.counts?(nil)).to be(false)
    end
  end

  describe "COVERED_COUNTS, the counts the schedule still covers" do
    it "holds every count below the threshold, and neither the threshold nor anything past it" do
      covered = described_class::COVERED_COUNTS

      expect(covered).to eq(...described_class::AFTER)
      expect([ 0, described_class::AFTER - 1 ].map { |count| covered.cover?(count) }).to all(be(true))
      expect([ described_class::AFTER, described_class::AFTER + 5 ].map { |count| covered.cover?(count) }).to all(be(false))
    end

    it "is the one definition, with no second predicate beside it" do
      expect(described_class).not_to respond_to(:held?)
    end
  end

  it "reads plain values and no database" do
    queries = []
    counting = ->(*, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(counting, "sql.active_record") do
      described_class.counts?("bad_key")
      described_class::COVERED_COUNTS.cover?(2)
    end

    expect(queries).to be_empty
  end
end
