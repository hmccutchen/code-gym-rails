require "rails_helper"

RSpec.describe CodeReviewHelper, type: :helper do
  describe "#changed_lines_label" do
    it "names a single changed line" do
      expect(helper.changed_lines_label([ 4 ])).to eq("changed line 4")
    end

    it "joins runs of consecutive lines into en-dash ranges" do
      expect(helper.changed_lines_label([ 3, 4, 5, 9 ])).to eq("changed lines 3–5, 9")
      expect(helper.changed_lines_label([ 1, 2 ])).to eq("changed lines 1–2")
      expect(helper.changed_lines_label([ 2, 7, 11 ])).to eq("changed lines 2, 7, 11")
    end

    it "reads the numbers in order whatever order they come in" do
      expect(helper.changed_lines_label([ 9, 4, 3, 5 ])).to eq("changed lines 3–5, 9")
    end

    it "is empty when no line changed" do
      expect(helper.changed_lines_label([])).to eq("")
    end
  end
end
