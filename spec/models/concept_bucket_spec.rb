require "rails_helper"

RSpec.describe ConceptBucket do
  describe ".for" do
    it "buckets the architecture section independently of the day's language" do
      expect(described_class.for("architecture", "ruby_rails")).to eq("architecture")
      expect(described_class.for("architecture", "javascript")).to eq("architecture")
    end

    it "buckets pseudocode_to_code independently of the day's language" do
      expect(described_class.for("pseudocode_to_code", "ruby_rails")).to eq("pseudocode_to_code")
      expect(described_class.for("pseudocode_to_code", "javascript")).to eq("pseudocode_to_code")
    end

    it "buckets every other section under the day's language" do
      expect(described_class.for("code_review", "ruby_rails")).to eq("ruby_rails")
      expect(described_class.for("pattern", "javascript")).to eq("javascript")
      expect(described_class.for("security_review", "javascript")).to eq("javascript")
      expect(described_class.for("challenge", "ruby_rails")).to eq("ruby_rails")
    end

    # One concept on several sections is one exposure; see ConceptMastery.record_review!.
    it "takes the architecture bucket when any section in a list is architecture" do
      expect(described_class.for(%w[code_review architecture], "javascript")).to eq("architecture")
      expect(described_class.for(%w[architecture pattern], "ruby_rails")).to eq("architecture")
    end

    it "buckets a list under the language when no section is architecture" do
      expect(described_class.for(%w[code_review pattern], "javascript")).to eq("javascript")
    end

    # User#concepts_needing_reinforcement reads the language with `&.`, so nil must not raise.
    it "passes a nil language through as a nil bucket" do
      expect(described_class.for("code_review", nil)).to be_nil
    end

    it "still buckets architecture even when the language is nil" do
      expect(described_class.for("architecture", nil)).to eq("architecture")
    end

    it "buckets plan_review independently of the day's language" do
      expect(described_class.for("plan_review", "ruby_rails")).to eq("plan_review")
      expect(described_class.for("plan_review", "javascript")).to eq("plan_review")
    end

    it "buckets ambiguity_hunt independently of the day's language" do
      expect(described_class.for("ambiguity_hunt", "ruby_rails")).to eq("ambiguity_hunt")
      expect(described_class.for("ambiguity_hunt", "javascript")).to eq("ambiguity_hunt")
    end

    it "takes the plan_review bucket when any section in a list is plan_review" do
      expect(described_class.for(%w[code_review plan_review], "javascript")).to eq("plan_review")
    end

    it "still buckets plan_review and ambiguity_hunt even when the language is nil" do
      expect(described_class.for("plan_review", nil)).to eq("plan_review")
      expect(described_class.for("ambiguity_hunt", nil)).to eq("ambiguity_hunt")
    end

    # A bucket of a concept's own would need a section kind; per-language mastery is the accepted cost.
    it "buckets on section key alone, so no concept can claim a bucket of its own" do
      expect(described_class.for("code_review", "ruby_rails")).to eq("ruby_rails")
      expect(described_class.for("pattern", "javascript")).to eq("javascript")
    end
  end

  describe ".vocabulary_for" do
    it "answers with the vocabulary each bucket draws from" do
      expect(described_class.vocabulary_for("ruby_rails")).to eq(AiService::RAILS_CONCEPTS)
      expect(described_class.vocabulary_for("javascript")).to eq(AiService::JS_CONCEPTS)
      expect(described_class.vocabulary_for("architecture")).to eq(AiService::ARCHITECTURE_CONCEPTS)
      expect(described_class.vocabulary_for("plan_review")).to eq(AiService::PLAN_REVIEW_CONCEPTS)
      expect(described_class.vocabulary_for("ambiguity_hunt")).to eq(AiService::AMBIGUITY_HUNT_CONCEPTS)
      expect(described_class.vocabulary_for("pseudocode_to_code")).to eq(AiService::PSEUDOCODE_TO_CODE_CONCEPTS)
    end

    # An empty list would silently read as "nothing is due" in a retention query.
    it "raises for a bucket with no vocabulary rather than returning nothing" do
      expect { described_class.vocabulary_for("not_a_bucket") }.to raise_error(KeyError)
    end
  end

  describe ".language_buckets_for" do
    it "is the language itself for a single-language user" do
      expect(described_class.language_buckets_for("javascript")).to eq([ "javascript" ])
    end

    it "is every programming language for a mixed user" do
      expect(described_class.language_buckets_for("mixed")).to match_array(DailyExercise::LANGUAGES)
    end
  end
end
