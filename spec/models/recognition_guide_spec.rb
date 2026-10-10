require "rails_helper"

RSpec.describe RecognitionGuide do
  it "covers every named display group and every language-independent bucket" do
    expect(described_class::GROUP_KEYS)
      .to match_array(ConceptGroup::NAMED.map(&:first) + ConceptBucket::LANGUAGE_INDEPENDENT)
  end

  # key_for reads group and bucket keys through one list, so a shared name would answer for both.
  it "has no group key that is also a bucket's" do
    expect(ConceptGroup::NAMED.map(&:first) & AiService::LANGUAGE_CONFIG.keys).to be_empty
  end

  it "states a subject for every group" do
    described_class::GROUP_KEYS.each do |key|
      expect(described_class.subject_for(key)).to be_present, key
    end
  end

  it "frames only groups that exist" do
    expect(described_class::FRAMINGS.keys - described_class::GROUP_KEYS).to be_empty
  end

  describe ".key_for" do
    it "names a language bucket's named group" do
      expect(described_class.key_for("ruby_rails", "code_smell")).to eq("code_smell")
      expect(described_class.key_for("javascript", "code_smell")).to eq("code_smell")
    end

    it "gives a language bucket's core group no guide" do
      DailyExercise::LANGUAGES.each do |language|
        expect(described_class.key_for(language, ConceptGroup::CORE)).to be_nil
      end
    end

    it "treats a language-independent bucket's flat list as its own group" do
      ConceptBucket::LANGUAGE_INDEPENDENT.each do |bucket|
        expect(ConceptGroup.grouped(ConceptBucket.vocabulary_for(bucket)).map(&:first)).to eq([ ConceptGroup::CORE ])
        expect(described_class.key_for(bucket, ConceptGroup::CORE)).to eq(bucket)
      end
    end
  end

  describe ".concepts_for" do
    it "reads a named group's concepts from ConceptGroup" do
      expect(described_class.concepts_for("meta_skill")).to eq(AiService::META_SKILL_CONCEPTS)
    end

    it "reads a bucket's concepts from its vocabulary" do
      expect(described_class.concepts_for("architecture")).to eq(AiService::ARCHITECTURE_CONCEPTS)
    end
  end

  def guide(**overrides)
    described_class.new(group_key: "code_smell", questions: "q", contrast: "c", misfires: "m", **overrides)
  end

  it "refuses a key outside the recognition groups" do
    expect(guide(group_key: "core")).not_to be_valid
    expect(guide).to be_valid
  end

  AiService::RECOGNITION_GUIDE_FIELDS.each do |field|
    it "refuses a guide with no #{field}" do
      expect(guide(field => " ")).not_to be_valid
    end

    it "refuses a row with no #{field} at the database too" do
      guide.save!

      expect { described_class.update_all(field => nil) }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end
end
