require "rails_helper"

RSpec.describe ConceptBucket do
  it "recognizes only closed string concept/bucket identities" do
    expect(described_class.valid_identity?(concept: "memoization", bucket: "ruby_rails")).to be(true)
    [ [ "invented", "ruby_rails" ], [ "memoization", "invented" ], [ nil, "ruby_rails" ],
      [ :memoization, "ruby_rails" ], [ "memoization", :ruby_rails ], [ {}, [] ] ].each do |concept, bucket|
      expect(described_class.valid_identity?(concept: concept, bucket: bucket)).to be(false)
    end
  end

  it "distinguishes a valid global pair from an incompatible kind-qualified identity in both directions" do
    expect(described_class.valid_identity?(concept: "sync_vs_async", bucket: "architecture")).to be(true)
    expect(described_class.valid_kind_identity?(kind: "code_review", concept: "sync_vs_async", bucket: "architecture")).to be(false)
    expect(described_class.valid_kind_identity?(kind: "architecture", concept: "memoization", bucket: "ruby_rails")).to be(false)
  end

  it "accepts kind identities recordable under either supported exercise language" do
    [ [ "code_review", "ruby_rails", "memoization" ], [ "code_review", "javascript", "closures" ],
      [ "architecture", "architecture", "sync_vs_async" ] ].each do |kind, bucket, concept|
      expect(described_class.valid_kind_identity?(kind: kind, concept: concept, bucket: bucket)).to be(true)
    end
  end

  it "requires a registered kind and a closed concept/bucket pair" do
    [ nil, "invented" ].each do |kind|
      expect(described_class.valid_kind_identity?(kind: kind, concept: "memoization", bucket: "ruby_rails")).to be(false)
    end
    expect(described_class.valid_kind_identity?(kind: "code_review", concept: "invented", bucket: "ruby_rails")).to be(false)
    expect(described_class.valid_kind_identity?(kind: "code_review", concept: "memoization", bucket: nil)).to be(false)
  end

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
      expect(described_class.vocabulary_for("ruby_rails")).to eq(ConceptVocabulary::RAILS_CONCEPTS)
      expect(described_class.vocabulary_for("javascript")).to eq(ConceptVocabulary::JS_CONCEPTS)
      expect(described_class.vocabulary_for("architecture")).to eq(ConceptVocabulary::ARCHITECTURE_CONCEPTS)
      expect(described_class.vocabulary_for("plan_review")).to eq(ConceptVocabulary::PLAN_REVIEW_CONCEPTS)
      expect(described_class.vocabulary_for("ambiguity_hunt")).to eq(ConceptVocabulary::AMBIGUITY_HUNT_CONCEPTS)
      expect(described_class.vocabulary_for("pseudocode_to_code")).to eq(ConceptVocabulary::PSEUDOCODE_TO_CODE_CONCEPTS)
    end

    # An empty list would silently read as "nothing is due" in a retention query.
    it "raises for a bucket with no vocabulary rather than returning nothing" do
      expect { described_class.vocabulary_for("not_a_bucket") }.to raise_error(ConceptVocabulary::UnknownLanguage)
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
