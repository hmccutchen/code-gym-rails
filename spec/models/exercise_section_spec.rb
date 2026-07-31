require "rails_helper"

RSpec.describe ExerciseSection do
  describe ".keys" do
    it "lists every section kind in the order the app has always enumerated them" do
      expect(described_class.keys).to eq(%w[code_review pattern challenge architecture security_review parsons_problem])
    end
  end

  describe ".find" do
    it "resolves a key to its section kind" do
      expect(described_class.find("architecture")).to eq(ExerciseSection::Architecture)
      expect(described_class.find(:security_review)).to eq(ExerciseSection::SecurityReview)
    end

    # A provider can put arbitrary keys in a jsonb payload, so callers get nil
    # to decide on rather than an exception.
    it "returns nil for a key outside the closed set" do
      expect(described_class.find("bogus")).to be_nil
    end
  end

  describe ".thirds" do
    # Precedence, not enumeration order — DailyExercise#third_key relies on
    # architecture winning over security_review over challenge.
    it "lists the third-slot kinds in resolution precedence order" do
      expect(described_class.thirds.map(&:key)).to eq(%w[architecture security_review challenge parsons_problem])
    end

    it "marks only the third-slot kinds as third?" do
      expect(described_class.find("code_review").third?).to be(false)
      expect(described_class.find("pattern").third?).to be(false)
      expect(described_class.find("challenge").third?).to be(true)
      expect(described_class.find("architecture").third?).to be(true)
      expect(described_class.find("security_review").third?).to be(true)
      expect(described_class.find("parsons_problem").third?).to be(true)
    end

    it "covers every third kind with a roll weight, so the two can't drift apart" do
      expect(DailyPlan::THIRD_SECTION_WEIGHTS.keys.map(&:to_s)).to match_array(described_class.thirds.map(&:key))
    end
  end

  describe ".vocabulary_key" do
    it "sends architecture to the language-independent vocabulary" do
      expect(described_class.find("architecture").vocabulary_key).to eq(:architecture)
    end

    it "restricts security_review to the security subset" do
      expect(described_class.find("security_review").vocabulary_key).to eq(:security_concepts)
    end

    it "sends every other kind to the day's full language vocabulary" do
      %w[code_review pattern challenge parsons_problem].each do |key|
        expect(described_class.find(key).vocabulary_key).to eq(:concepts)
      end
    end
  end

  describe ".improved_code?" do
    it "excludes architecture, whose review has no single corrected form" do
      expect(described_class.find("architecture").improved_code?).to be(false)
    end

    it "excludes parsons_problem, whose correct order is already the answer" do
      expect(described_class.find("parsons_problem").improved_code?).to be(false)
    end

    it "allows every other kind to carry corrected code" do
      %w[code_review pattern challenge security_review].each do |key|
        expect(described_class.find(key).improved_code?).to be(true)
      end
    end
  end

  describe ExerciseSection::ParsonsProblem do
    describe ".parse_order" do
      it "parses the order: prefix into 0-based integer ids" do
        expect(ExerciseSection::ParsonsProblem.parse_order("order:2,0,4,1,3")).to eq([ 2, 0, 4, 1, 3 ])
      end

      it "returns an empty array for a blank answer" do
        expect(ExerciseSection::ParsonsProblem.parse_order("")).to eq([])
        expect(ExerciseSection::ParsonsProblem.parse_order(nil)).to eq([])
      end

      it "returns an empty array for a malformed answer missing the prefix" do
        expect(ExerciseSection::ParsonsProblem.parse_order("2,0,4,1,3")).to eq([])
      end

      it "drops non-integer segments rather than raising" do
        expect(ExerciseSection::ParsonsProblem.parse_order("order:2,x,4")).to eq([ 2, 4 ])
      end
    end

    describe ".grade" do
      it "rates an exact match as strong with zero mismatches" do
        expect(ExerciseSection::ParsonsProblem.grade([ 0, 1, 2, 3, 4 ], 5)).to eq(mismatches: 0, rating: "strong")
      end

      it "rates a single adjacent swap (2 mismatches) as solid" do
        expect(ExerciseSection::ParsonsProblem.grade([ 1, 0, 2, 3, 4 ], 5)).to eq(mismatches: 2, rating: "solid")
      end

      it "rates a 3-cycle (3 mismatches, within half of 6) as developing" do
        expect(ExerciseSection::ParsonsProblem.grade([ 1, 2, 0, 3, 4, 5 ], 6)).to eq(mismatches: 3, rating: "developing")
      end

      it "rates more than half the blocks misplaced as beginner" do
        # A 5-element reversal leaves the middle block in place, so 4 of 5 move.
        expect(ExerciseSection::ParsonsProblem.grade([ 4, 3, 2, 1, 0 ], 5)).to eq(mismatches: 4, rating: "beginner")
      end

      it "treats a fully blank/skipped submission as fully mismatched" do
        expect(ExerciseSection::ParsonsProblem.grade([], 5)).to eq(mismatches: 5, rating: "beginner")
      end

      it "treats an out-of-range or short submission as mismatched for the missing positions" do
        expect(ExerciseSection::ParsonsProblem.grade([ 0, 1 ], 5)).to eq(mismatches: 3, rating: "developing")
      end
    end
  end
end
