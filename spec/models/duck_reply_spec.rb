require "rails_helper"

RSpec.describe DuckReply do
  def read(raw, truncated: false) = described_class.read(raw, truncated: truncated)

  describe ".read" do
    it "strips a label on the last line from the shown text and keeps it as the point" do
      reply = read("What does each pass through the loop ask for?\nPoint: The loop body")

      expect(reply).to have_attributes(text: "What does each pass through the loop ask for?", point: "the loop body")
    end

    it "keeps one form of a label, whatever its spacing, case or closing full stop" do
      expect(read("What runs?\n  Point:   Query   COUNT per row.").point).to eq("query count per row")
    end

    it "takes a label of two to five words" do
      expect(read("What runs?\nPoint: query count").point).to eq("query count")
      expect(read("What runs?\nPoint: one two three four five").point).to eq("one two three four five")
    end

    it "gives no point for a reply with no label line, and shows it whole" do
      expect(read("What runs first?")).to have_attributes(text: "What runs first?", point: nil)
    end

    it "gives no point for an empty label, a single word or more than five words, and still hides the line" do
      [ "Point:", "Point:   ", "Point: loop", "Point: one two three four five six" ].each do |line|
        expect(read("What runs first?\n#{line}")).to have_attributes(text: "What runs first?", point: nil)
      end
    end

    it "gives no point when the label is not on the last line, and still hides the line" do
      reply = read("Point: the loop body\nWhat runs first?")

      expect(reply).to have_attributes(text: "What runs first?", point: nil)
    end

    it "hides every standalone label line, keeping the point only from the last line" do
      reply = read("Look at the loop.\n  Point: an early label\nWhat runs first?\nPoint: the loop body")

      expect(reply).to have_attributes(text: "Look at the loop.\nWhat runs first?", point: "the loop body")
    end

    it "gives no point when the label shares a line with the question" do
      expect(read("What runs first? Point: the loop body").point).to be_nil
    end

    it "gives a reply the token cap cut short no point, even when its last line looks like a label" do
      expect(read("What runs first?\nPoint: the loop", truncated: true)).to have_attributes(text: "What runs first?…", point: nil)
      expect(read("What runs first in the", truncated: true)).to have_attributes(text: "What runs first in the…", point: nil)
    end

    it "refuses a reply that is nothing but its label" do
      expect { read("Point: the loop body") }.to raise_error(ProviderError::InvalidResponseError)
    end
  end

  describe "#question?" do
    it "is true only when the shown text ends in a question mark" do
      expect(read("What runs first?\nPoint: the loop body").question?).to be(true)
      expect(read("The loop runs first.").question?).to be(false)
      expect(read("What runs first", truncated: true).question?).to be(false)
    end
  end

  describe ".with_point" do
    it "writes a label back so .read gives the same text and point" do
      written = described_class.with_point("What does each pass ask for?", "the loop body")

      expect(described_class.read(written, truncated: false)).to eq(described_class.new(text: "What does each pass ask for?", point: "the loop body"))
    end

    it "leaves a text with no point as it is" do
      expect(described_class.with_point("What runs first?", nil)).to eq("What runs first?")
    end
  end

  describe ".quote_outcome" do
    let(:context) { "Question: Find the bug\nCode snippet:\nCustomer.all.each do |customer|\n  customer.invoices.open.sum(:total)\nend" }

    def outcome(text) = described_class.quote_outcome(text, within: context, language: "ruby_rails")

    it "finds a backticked quote in the exercise text, ignoring whitespace" do
      expect(outcome("Look at `customer.invoices.open.sum( :total )`. What runs there?")).to eq("found")
      expect(outcome("Look at `Customer.all.each do |customer|  customer.invoices`. What runs?")).to eq("found")
    end

    it "reports a quote that is not in the exercise text as missing" do
      expect(outcome("Look at `includes(:invoices)`. What would change?")).to eq("missing")
    end

    it "reports a reply with no quote, or only an empty one, as none" do
      expect(outcome("Look at the loop. What runs there?")).to eq("none")
      expect(outcome("Look at ` `. What runs there?")).to eq("none")
    end

    it "checks the first quote" do
      expect(outcome("Compare `includes(:invoices)` with `Customer.all`.")).to eq("missing")
    end

    it "skips a quote too short to check, the way the key's quote check does" do
      expect(outcome("Look at `a`. What runs?")).to eq("none")
      expect(outcome("Compare `do` with `customer.invoices`.")).to eq("found")
    end
  end
end
