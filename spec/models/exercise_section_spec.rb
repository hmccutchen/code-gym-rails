require "rails_helper"

RSpec.describe ExerciseSection do
  describe ".keys" do
    it "lists every section kind in the order the app has always enumerated them" do
      expect(described_class.keys).to eq(%w[code_review pattern challenge architecture security_review])
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
      expect(described_class.thirds.map(&:key)).to eq(%w[architecture security_review challenge])
    end

    it "marks only the third-slot kinds as third?" do
      expect(described_class.find("code_review").third?).to be(false)
      expect(described_class.find("pattern").third?).to be(false)
      expect(described_class.find("challenge").third?).to be(true)
      expect(described_class.find("architecture").third?).to be(true)
      expect(described_class.find("security_review").third?).to be(true)
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
      %w[code_review pattern challenge].each do |key|
        expect(described_class.find(key).vocabulary_key).to eq(:concepts)
      end
    end
  end

  describe ".improved_code?" do
    it "excludes architecture, whose review has no single corrected form" do
      expect(described_class.find("architecture").improved_code?).to be(false)
    end

    it "allows every other kind to carry corrected code" do
      %w[code_review pattern challenge security_review].each do |key|
        expect(described_class.find(key).improved_code?).to be(true)
      end
    end
  end
end
