require "rails_helper"

RSpec.describe ConceptBucket do
  describe ".for" do
    it "buckets the architecture section independently of the day's language" do
      expect(described_class.for("architecture", "ruby_rails")).to eq("architecture")
      expect(described_class.for("architecture", "javascript")).to eq("architecture")
    end

    it "buckets every other section under the day's language" do
      expect(described_class.for("code_review", "ruby_rails")).to eq("ruby_rails")
      expect(described_class.for("pattern", "javascript")).to eq("javascript")
      expect(described_class.for("security_review", "javascript")).to eq("javascript")
      expect(described_class.for("challenge", "ruby_rails")).to eq("ruby_rails")
    end

    # A concept tagged on several sections the same day is one exposure, and it
    # belongs to the architecture bucket if any of those sections is the
    # architecture one — see ConceptMastery.record_review!.
    it "takes the architecture bucket when any section in a list is architecture" do
      expect(described_class.for(%w[code_review architecture], "javascript")).to eq("architecture")
      expect(described_class.for(%w[architecture pattern], "ruby_rails")).to eq("architecture")
    end

    it "buckets a list under the language when no section is architecture" do
      expect(described_class.for(%w[code_review pattern], "javascript")).to eq("javascript")
    end

    # User#concepts_needing_reinforcement reads the language off a response's
    # exercise with `&.`, so a response whose exercise is missing yields no
    # bucket rather than raising.
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

    # Pins design question 1: these concepts are language-independent in
    # meaning, but ConceptBucket dispatches on section key and never on
    # concept, so a bucket of their own would require a section kind — which
    # this deliberately is not. Per-language mastery is the accepted cost.
    it "buckets on section key alone, so no concept can claim a bucket of its own" do
      expect(described_class.for("code_review", "ruby_rails")).to eq("ruby_rails")
      expect(described_class.for("pattern", "javascript")).to eq("javascript")
    end
  end
end
