require "rails_helper"

RSpec.describe ExerciseSection::ParsonsProblem do
  describe ".arrange!" do
    it "writes a display order that is a permutation of the blocks" do
      section = { "blocks" => %w[a b c d e] }

      described_class.arrange!(section)

      expect(section["display_order"]).to match_array([ 0, 1, 2, 3, 4 ])
    end

    it "never writes the stored order, which is the solved one" do
      20.times do
        section = { "blocks" => %w[a b c] }
        described_class.arrange!(section)
        expect(section["display_order"]).not_to eq([ 0, 1, 2 ])
      end
    end

    it "gives a single block the only order it has" do
      section = { "blocks" => %w[only] }

      described_class.arrange!(section)

      expect(section["display_order"]).to eq([ 0 ])
    end

    it "leaves a section with no blocks array untouched" do
      section = { "question" => "q", "blocks" => "not a list" }

      described_class.arrange!(section)

      expect(section).to eq("question" => "q", "blocks" => "not a list")
    end
  end
end
