require "rails_helper"

RSpec.describe UsageCounts do
  subject(:counts) { described_class.new(GeminiService) }

  let(:largest) { ApiUsage.max_token_count }

  before { allow(Rails.logger).to receive(:warn) }

  def marked = counts.mark(input_tokens: 1)

  describe "#count" do
    [ 0, 7 ].each do |value|
      it "returns #{value} and records no problem when the count is #{value}" do
        expect(counts.count({ "n" => value }, "n")).to eq(value)
        expect(marked).to eq(input_tokens: 1)
      end
    end

    it "accepts the largest count a usage row holds" do
      expect(counts.count({ "n" => largest }, "n")).to eq(largest)
      expect(marked).not_to have_key(:tokens_unknown)
    end

    it "reads zero and marks the counts unknown when the count is more than a usage row holds" do
      expect(counts.count({ "n" => largest + 1 }, "n")).to eq(0)
      expect(marked).to include(tokens_unknown: true)
    end

    [ -1, "5", 5.0, { "n" => 5 }, [ 5 ], true ].each do |value|
      it "reads zero and marks the counts unknown when the count is #{value.inspect}" do
        expect(counts.count({ "n" => value }, "n")).to eq(0)
        expect(marked).to include(tokens_unknown: true)
      end
    end

    it "reads an absent or null optional count as zero and records no problem" do
      expect(counts.count({}, "n")).to eq(0)
      expect(counts.count({ "n" => nil }, "n")).to eq(0)
      expect(marked).to eq(input_tokens: 1)
    end

    [ {}, { "n" => nil } ].each do |parent|
      it "reads zero and marks the counts unknown when a required count is #{parent.empty? ? 'absent' : 'null'}" do
        expect(counts.count(parent, "n", required: true)).to eq(0)
        expect(marked).to include(tokens_unknown: true)
        expect(Rails.logger).to have_received(:warn).with(a_string_including("n is missing")).once
      end
    end

    it "takes a required count that is present and valid" do
      expect(counts.count({ "n" => 3 }, "n", required: true)).to eq(3)
      expect(marked).to eq(input_tokens: 1)
    end
  end

  describe "#object" do
    it "returns the object when the value is a hash" do
      expect(counts.object({ "usage" => { "n" => 1 } }, "usage")).to eq("n" => 1)
      expect(marked).to eq(input_tokens: 1)
    end

    [ "usage", [ 1 ], 5 ].each do |value|
      it "returns an empty object and marks the counts unknown when the value is #{value.inspect}" do
        expect(counts.object({ "usage" => value }, "usage")).to eq({})
        expect(marked).to include(tokens_unknown: true)
      end
    end

    it "returns an empty object and records no problem when an optional object is absent or null" do
      expect(counts.object({}, "usage")).to eq({})
      expect(counts.object({ "usage" => nil }, "usage")).to eq({})
      expect(marked).to eq(input_tokens: 1)
    end

    [ {}, { "usage" => nil } ].each do |parent|
      it "marks the counts unknown when a required object is #{parent.empty? ? 'absent' : 'null'}" do
        expect(counts.object(parent, "usage", required: true)).to eq({})
        expect(marked).to include(tokens_unknown: true)
      end
    end
  end

  describe "#uncached" do
    it "subtracts every cache count from the total" do
      expect(counts.uncached(10, 3, 2, field: "input_tokens")).to eq(5)
      expect(marked).to eq(input_tokens: 1)
    end

    it "returns zero when the cache counts use up the whole total" do
      expect(counts.uncached(5, 3, 2, field: "input_tokens")).to eq(0)
      expect(marked).to eq(input_tokens: 1)
    end

    it "floors at zero and names the field when the cache counts add up to more than the total" do
      expect(counts.uncached(4, 3, 2, field: "input_tokens")).to eq(0)
      expect(marked).to include(tokens_unknown: true)
      expect(Rails.logger).to have_received(:warn).with(a_string_including("input_tokens")).once
    end
  end

  describe "#sum" do
    it "adds the counts when the total fits a usage row" do
      expect(counts.sum(largest - 1, 1, field: "output_tokens")).to eq(largest)
      expect(marked).to eq(input_tokens: 1)
    end

    it "returns zero and names the field when the total is more than a usage row holds" do
      expect(counts.sum(largest, 1, field: "output_tokens")).to eq(0)
      expect(marked).to include(tokens_unknown: true)
      expect(Rails.logger).to have_received(:warn).with(a_string_including("output_tokens")).once
    end
  end

  describe "#mark" do
    it "returns the same hash and warns nothing when every count was read" do
      result = { input_tokens: 1 }

      expect(counts.mark(result)).to equal(result)
      expect(Rails.logger).not_to have_received(:warn)
    end

    it "marks the counts unknown with one warning that names the provider and every field" do
      counts.count({ "a" => "x" }, "a")
      counts.count({}, "b", required: true)

      expect(marked).to eq(input_tokens: 1, tokens_unknown: true)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("[usage]", "GeminiService", "a is not a valid count", "b is missing")).once
    end

    it "never puts a count's value in the warning" do
      counts.count({ "a" => "leaked-value-77" }, "a")
      counts.object({ "usage" => "leaked-object-88" }, "usage")
      counts.count({ "c" => 2**40 }, "c")
      marked

      expect(Rails.logger).to have_received(:warn)
        .with(satisfy { |line| %w[leaked-value-77 leaked-object-88 1099511627776].none? { |value| line.include?(value) } }).once
    end
  end

  it "keeps its count check private" do
    expect(described_class).not_to respond_to(:valid?)
  end
end
