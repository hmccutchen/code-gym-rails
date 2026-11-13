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

  let(:owner) { User.create!(email: "guide-owner@example.com") }
  let(:other) { User.create!(email: "guide-other@example.com") }

  def guide(**overrides)
    described_class.new(group_key: "code_smell", questions: "q", contrast: "c", misfires: "m", user: owner, **overrides)
  end

  it "refuses a key outside the recognition groups" do
    expect(guide(group_key: "core")).not_to be_valid
    expect(guide).to be_valid
  end

  it "requires an owner, in the model and in the database" do
    ownerless = guide(user: nil)

    expect(ownerless).not_to be_valid
    expect { ownerless.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
  end

  describe "ownership" do
    def create_guide(**attributes)
      described_class.create!(group_key: "code_smell", questions: "q", contrast: "c", misfires: "m", **attributes)
    end

    it "lets each user hold the same group key once" do
      create_guide(user: owner)

      expect(guide(user: other)).to be_valid
      expect(guide(user: owner)).not_to be_valid
    end

    it "indexes the user's own guides by group key, never another user's" do
      own = create_guide(questions: "own", user: owner)
      create_guide(questions: "theirs", user: other)
      create_guide(group_key: "data_modeling", user: other)

      expect(described_class.indexed_for(owner, %w[code_smell architecture data_modeling])).to eq("code_smell" => own)
      expect(described_class.indexed_for(other, %w[architecture])).to be_empty
      expect(owner.recognition_guides).to contain_exactly(own)
    end

    it "says whether the user has their own guide for one key, ignoring other users' rows" do
      create_guide(user: other)

      expect(described_class.written_for?(owner, "code_smell")).to be(false)
      expect(described_class.written_for?(other, "code_smell")).to be(true)
    end

    it "lists the group keys a user has no guide of their own for, in the order given" do
      create_guide(group_key: "architecture", user: other)
      create_guide(group_key: "data_modeling", user: other)
      create_guide(user: owner)

      expect(described_class.missing_for(owner, %w[code_smell data_modeling architecture oo_design]))
        .to eq(%w[data_modeling architecture oo_design])
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

  describe ".write_for" do
    let(:writer) { User.create!(email: "guide-writer@example.com") }
    let(:reply) { { "questions" => "q", "contrast" => "c", "misfires" => "m", "extra" => "dropped" } }

    def write = described_class.write_for(writer, group_key: "code_smell", guide: reply)

    it "creates the user's own guide from the guide's fields" do
      expect(write).to eq(:written)

      row = described_class.sole
      expect([ row.user, row.group_key, row.questions, row.contrast, row.misfires ]).to eq([ writer, "code_smell", "q", "c", "m" ])
    end

    it "writes nothing for an account deleted before the write" do
      User.where(id: writer.id).delete_all

      expect(write).to eq(:account_deleted)
      expect(described_class.count).to eq(0)
    end

    it "share-locks the owner before it inserts" do
      pattern = /FOR SHARE|INSERT INTO "recognition_guides"/
      statements = []
      subscriber = ->(*, payload) { statements << payload[:sql][pattern] if payload[:sql].match?(pattern) }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { write }

      expect(statements).to eq([ "FOR SHARE", 'INSERT INTO "recognition_guides"' ])
    end
  end
end
