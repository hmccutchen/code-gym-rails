require "rails_helper"

RSpec.describe ExerciseSection::ParsonsProblem do
  describe ".block_token and .decode_answer" do
    let(:section_data) { { "blocks" => %w[a b c] } }
    let(:exercise) { instance_double(DailyExercise, id: 7) }

    def token(block_id, for_exercise: exercise, key: "parsons_problem")
      described_class.block_token(block_id, exercise: for_exercise, key: key)
    end

    def decode(value, for_exercise: exercise)
      described_class.decode_answer(value, exercise: for_exercise, key: "parsons_problem",
                                           section_data: section_data)
    end

    it "reads an order of tokens back as the positions they stand for" do
      expect(decode("order:#{token(2)},#{token(0)},#{token(1)}")).to eq("order:2,0,1")
    end

    it "says nothing about the correct order: sorting the tokens is not sorting the blocks" do
      tokens = (0..2).map { |id| token(id) }

      expect(tokens.sort).not_to eq(tokens)
    end

    it "gives a different exercise and a different section different tokens for the same block" do
      expect(token(0)).not_to eq(token(0, for_exercise: instance_double(DailyExercise, id: 8)))
      expect(token(0)).not_to eq(token(0, key: "pattern"))
    end

    it "leaves a token from another exercise alone rather than inventing a position" do
      other = token(0, for_exercise: instance_double(DailyExercise, id: 8))

      expect(decode("order:#{other},#{token(1)},#{token(2)}")).to eq("order:#{other},#{token(1)},#{token(2)}")
    end

    it "carries a stored positional answer through unchanged" do
      expect(decode("order:2,0,1")).to eq("order:2,0,1")
    end

    it "leaves an answer alone when the section has no blocks to map it to" do
      expect(described_class.decode_answer("order:2,0,1", exercise: exercise, key: "parsons_problem",
                                                          section_data: { "blocks" => [] })).to eq("order:2,0,1")
    end
  end

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
