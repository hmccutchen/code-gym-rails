require "rails_helper"

RSpec.describe RecognitionGuide do
  it "covers every named display group and every language-independent bucket" do
    expect(described_class::GROUP_KEYS)
      .to match_array(ConceptGroup::NAMED.map(&:first) + ConceptBucket::LANGUAGE_INDEPENDENT)
  end

  # key_for reads group and bucket keys through one list, so a shared name would answer for both.
  it "has no group key that is also a bucket's" do
    expect(ConceptGroup::NAMED.map(&:first) & ConceptVocabulary.languages).to be_empty
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
      expect(described_class.concepts_for("meta_skill")).to eq(ConceptVocabulary::META_SKILL_CONCEPTS)
    end

    it "reads a bucket's concepts from its vocabulary" do
      expect(described_class.concepts_for("architecture")).to eq(ConceptVocabulary::ARCHITECTURE_CONCEPTS)
    end
  end

  def guide(**overrides)
    described_class.new(group_key: "code_smell", questions: "q", contrast: "c", misfires: "m", **overrides)
  end

  it "refuses a key outside the recognition groups" do
    expect(guide(group_key: "core")).not_to be_valid
    expect(guide).to be_valid
  end

  describe "ownership" do
    let(:owner) { User.create!(email: "guide-owner@example.com") }
    let(:other) { User.create!(email: "guide-other@example.com") }

    def create_guide(**attributes)
      described_class.create!(group_key: "code_smell", questions: "q", contrast: "c", misfires: "m", **attributes)
    end

    it "lets each user and the shared row hold the same group key" do
      create_guide
      create_guide(user: owner)

      expect(guide(user: other)).to be_valid
      expect(guide(user: owner)).not_to be_valid
      expect(guide).not_to be_valid
    end

    it "indexes the guides a user sees by group key, their own over the shared one, never another user's" do
      create_guide(questions: "shared")
      own = create_guide(questions: "own", user: owner)
      shared_only = create_guide(group_key: "architecture")
      create_guide(group_key: "data_modeling", user: other)

      expect(described_class.seen_by(owner, %w[code_smell architecture data_modeling]))
        .to eq("code_smell" => own, "architecture" => shared_only)
      expect(described_class.seen_by(other, %w[code_smell]).fetch("code_smell").questions).to eq("shared")
      expect(described_class.visible_to(owner)).not_to include(described_class.find_by!(user: other))
    end

    it "lists the group keys a user sees no guide for, in the order given, ignoring another user's guide" do
      create_guide(group_key: "architecture")
      create_guide(group_key: "data_modeling", user: other)
      create_guide(user: owner)

      expect(described_class.missing_for(owner, %w[code_smell data_modeling architecture oo_design]))
        .to eq(%w[data_modeling oo_design])
      expect(described_class.missing_for(owner, [])).to eq([])
    end
  end

  RecognitionGuide::FIELDS.each do |field|
    it "refuses a guide with no #{field}" do
      expect(guide(field => " ")).not_to be_valid
    end

    it "refuses a row with no #{field} at the database too" do
      guide.save!

      expect { described_class.update_all(field => nil) }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end
end
