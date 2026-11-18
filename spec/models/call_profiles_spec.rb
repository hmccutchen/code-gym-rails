require "rails_helper"

RSpec.describe CallProfiles do
  it "raises for a purpose with no profile, so a typo fails at the call site" do
    expect { described_class.fetch("generate_exercises") }.to raise_error(KeyError)
    expect { described_class.worst_case_seconds_for("generate_exercises") }.to raise_error(KeyError)
  end

  it "times a purpose with no read timeout of its own at the default, with every retry" do
    expect(described_class.worst_case_seconds_for("explain_differently"))
      .to eq(described_class.worst_case_call_seconds(described_class::READ_TIMEOUT))
  end

  it "times a single-attempt purpose as one connection and one read" do
    expect(described_class.worst_case_seconds_for("judge_review"))
      .to eq(described_class::OPEN_TIMEOUT + described_class::REVIEW_JUDGE_READ_TIMEOUT)
  end

  it "answers the same worst case as a request built from the same profile" do
    described_class::BY_PURPOSE.each_key do |purpose|
      request = AiService.request_for(purpose, system: "s", prompt: "p")

      expect(described_class.worst_case_seconds_for(purpose)).to eq(request.worst_case_seconds), purpose
    end
  end

  describe "the learner items cap" do
    let(:buckets) { ConceptBucket.slice_for("mixed") }
    let(:longest_concept) { buckets.flat_map { |bucket| ConceptBucket.vocabulary_for(bucket) }.max_by(&:length) }
    let(:longest_bucket) { buckets.max_by(&:length) }
    let(:longest_section) { ExerciseSection.keys.max_by(&:length) }

    def worst_case_reply
      reference = { "source" => "explanation", "section" => longest_section }
      item = { "concept" => longest_concept, "bucket" => longest_bucket, "kind" => "misconception",
               "term" => "t" * LearnerItem::MAX_TERM_LENGTH, "label" => "l" * LearnerItem::MAX_LABEL_LENGTH,
               "evidence" => Array.new(LearnerItem::MAX_EVIDENCE, reference) }
      JSON.generate({ "items" => Array.new(LearnerItem::MAX_OPEN + LearnerItem::MAX_NEW_PER_DAY, item) }, space: " ")
    end

    it "holds a repeat of every open item and the new items a day may add, each at its longest" do
      expect(LearnerItemsReply::MAX_REPLY_CHARS).to be >= worst_case_reply.length
      expect(described_class::LEARNER_ITEMS_MAX_TOKENS).to be >= worst_case_reply.length / described_class::PROSE_CHARS_PER_TOKEN
      expect(described_class::LEARNER_ITEMS_MAX_TOKENS).to be_an(Integer)
      expect(described_class.fetch("extract_learner_items")[:max_tokens]).to eq(described_class::LEARNER_ITEMS_MAX_TOKENS)
    end
  end
end
