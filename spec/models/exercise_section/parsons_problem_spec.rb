require "rails_helper"

RSpec.describe ExerciseSection::ParsonsProblem do
  describe ".block_token and .decode_answer" do
    let(:section_data) { { "blocks" => %w[a b c] } }
    let(:exercise) { instance_double(DailyExercise, id: 7) }

    def token(block_id, for_exercise: exercise, key: "parsons_problem", data: section_data)
      described_class.block_token(block_id, exercise: for_exercise, key: key, section_data: data)
    end

    def decode(value, for_exercise: exercise)
      described_class.decode_answer(value, exercise: for_exercise, key: "parsons_problem",
                                           section_data: section_data)
    end

    it "reads an order of tokens back as the positions they stand for" do
      expect(decode("order:#{token(2)},#{token(0)},#{token(1)}")).to eq("order:2,0,1")
    end

    it "says nothing about a block's position: the token is a signature over it" do
      problem = described_class.problem_digest(section_data)
      digest  = OpenSSL::HMAC.hexdigest(
        "SHA256", Rails.application.secret_key_base, "parsons:7:parsons_problem:#{problem}:0"
      )

      expect(token(0)).to eq(digest.first(described_class::TOKEN_LENGTH))
      expect(token(0)).to eq(token(0))
    end

    it "gives a different exercise and a different section different tokens for the same block" do
      expect(token(0)).not_to eq(token(0, for_exercise: instance_double(DailyExercise, id: 8)))
      expect(token(0)).not_to eq(token(0, key: "pattern"))
    end

    it "refuses a token from another exercise rather than inventing a position" do
      other = token(0, for_exercise: instance_double(DailyExercise, id: 8))

      expect(decode("order:#{other},#{token(1)},#{token(2)}")).to be_nil
    end

    it "refuses a positional order, which is the mapping the tokens withhold" do
      expect(decode("order:0,1,2")).to be_nil
      expect(decode("order:2,0,1")).to be_nil
    end

    # RegenerateExerciseJob writes the replacement problem_set onto the same
    # row, so the exercise id and the section key are both unchanged. Were the
    # blocks out of the signature, a token sequence learned from the set that
    # was replaced would still decode here, and submitting it would arrange a
    # puzzle nobody had read.
    it "refuses a token from the set a regeneration replaced, same row and same block count" do
      replaced = token(0, data: { "blocks" => %w[x y z] })

      expect(token(0)).not_to eq(replaced)
      expect(decode("order:#{replaced},#{token(1)},#{token(2)}")).to be_nil
    end

    it "keeps a token stable while the problem is unchanged, however it is read" do
      expect(token(0, data: { "blocks" => %w[a b c] })).to eq(token(0))
    end

    it "leaves an answer alone when the section has no blocks to map it to" do
      expect(described_class.decode_answer("order:2,0,1", exercise: exercise, key: "parsons_problem",
                                                          section_data: { "blocks" => [] })).to eq("order:2,0,1")
    end
  end

  describe ".token_answer" do
    let(:exercise) { instance_double(DailyExercise, id: 7) }

    let(:section_data) { { "blocks" => %w[a b c] } }

    def token_answer(answer, data: section_data)
      described_class.token_answer(answer: answer, exercise: exercise, key: "parsons_problem",
                                   section_data: data)
    end

    def token(block_id)
      described_class.block_token(block_id, exercise: exercise, key: "parsons_problem",
                                            section_data: section_data)
    end

    it "renders a stored order as the tokens the blocks carry, never the positions" do
      expect(token_answer("order:2,0,1")).to eq("order:#{token(2)},#{token(0)},#{token(1)}")
    end

    it "round-trips through .decode_answer, so a reloaded draft saves as itself" do
      decoded = described_class.decode_answer(
        token_answer("order:2,0,1"), exercise: exercise, key: "parsons_problem",
        section_data: section_data
      )

      expect(decoded).to eq("order:2,0,1")
    end

    it "renders blank for a draft that is not a complete permutation" do
      expect(token_answer("order:0,0,1")).to eq("")
      expect(token_answer("order:9")).to eq("")
      expect(token_answer(nil)).to eq("")
      expect(token_answer("")).to eq("")
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
