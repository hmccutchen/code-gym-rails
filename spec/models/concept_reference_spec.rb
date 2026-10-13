require "rails_helper"

RSpec.describe ConceptReference do
  it "is valid with a concept and language" do
    ref = ConceptReference.new(concept: "n_plus_one", language: "ruby_rails")
    expect(ref).to be_valid
  end

  it "requires a concept" do
    ref = ConceptReference.new(concept: nil, language: "ruby_rails")
    expect(ref).not_to be_valid
  end

  it "requires a language" do
    ref = ConceptReference.new(concept: "n_plus_one", language: nil)
    expect(ref).not_to be_valid
  end

  it "allows the same concept in different languages" do
    ConceptReference.create!(concept: "closures", language: "javascript")
    ref = ConceptReference.new(concept: "closures", language: "ruby_rails")
    expect(ref).to be_valid
  end

  it "rejects a duplicate concept+language at the model level" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails")
    ref = ConceptReference.new(concept: "n_plus_one", language: "ruby_rails")
    expect(ref).not_to be_valid
  end

  it "enforces uniqueness at the database level" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails")
    dup = ConceptReference.new(concept: "n_plus_one", language: "ruby_rails")
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe "#guide?" do
    def reference(**guide_fields)
      ConceptReference.new(
        concept: "n_plus_one", language: "ruby_rails",
        tagline: "t", explanation: "e", code_example: "c", senior_lens: "s",
        **guide_fields
      )
    end

    it "is false for a row generated before guides existed" do
      expect(reference).not_to be_guide
    end

    it "is false when only some guide fields came back" do
      expect(reference(guide_plain_language: "plain", guide_worked_example: "worked")).not_to be_guide
    end

    it "is false when a guide field is blank rather than nil" do
      expect(
        reference(guide_plain_language: "plain", guide_worked_example: "worked", guide_pitfalls: "  ")
      ).not_to be_guide
    end

    it "is true when every guide field is present" do
      expect(
        reference(guide_plain_language: "plain", guide_worked_example: "worked", guide_pitfalls: "pitfalls")
      ).to be_guide
    end
  end

  describe "difficulty ladder" do
    def reference(**attrs)
      ConceptReference.create!({ concept: "n_plus_one", language: "ruby_rails",
                                 tagline: "t", explanation: "e", code_example: "c", senior_lens: "s",
                                 guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x" }.merge(attrs))
    end

    let(:full_ladder) { { ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p" } }

    it "names one migrated column per level" do
      expect(AiService::CONCEPT_LADDER_FIELDS).to eq(KindDifficulty::LEVELS.map { |level| "ladder_#{level}" })
      expect(ConceptReference.column_names).to include(*AiService::CONCEPT_LADDER_FIELDS)
    end

    it "carries a ladder only when every rung is present" do
      expect(reference(**full_ladder)).to be_ladder
      expect(reference(concept: "caching", **full_ladder.merge(ladder_senior: nil))).not_to be_ladder
    end

    it "is complete only with both guide and ladder" do
      expect(reference(**full_ladder)).to be_complete
      expect(reference(concept: "caching")).not_to be_complete
      expect(reference(concept: "memoization", guide_pitfalls: nil, **full_ladder)).not_to be_complete
    end

    it "stays complete without a lesson, and is fully written only with one" do
      row = reference(**full_ladder)
      expect(row).to be_complete
      expect(row).not_to be_lesson
      expect(row).not_to be_fully_written

      row.update!(lesson: { "definition" => "d" })
      expect(row).to be_lesson
      expect(row).to be_fully_written
    end

    it "defaults historical rows to no completed generation and keeps unrelated updates out of the counter" do
      row = reference(**full_ladder)
      expect(row.generation_version).to eq(0)

      row.update!(ladder_senior: "changed")
      row.update!(explanation: "rewritten")

      expect(row.reload.generation_version).to eq(0)
    end

    describe ".ladder_rungs" do
      it "returns the level's rung for laddered rows in the bucket and vocabulary" do
        reference(**full_ladder)
        reference(concept: "caching")                                          # no ladder
        reference(concept: "memoization", **full_ladder)                       # not asked for
        reference(concept: "n_plus_one", language: "javascript", **full_ladder) # other bucket

        rungs = ConceptReference.ladder_rungs(bucket: "ruby_rails", concepts: %w[n_plus_one caching], level: "senior")

        expect(rungs).to eq("n_plus_one" => "s")
      end

      it "truncates a rung on read" do
        reference(**full_ladder.merge(ladder_junior: "x" * 500))

        rung = ConceptReference.ladder_rungs(bucket: "ruby_rails", concepts: %w[n_plus_one], level: "junior")["n_plus_one"]

        expect(rung.length).to eq(AiService::MAX_LADDER_RUNG_LENGTH)
      end

      it "refuses a level outside the vocabulary" do
        expect { ConceptReference.ladder_rungs(bucket: "ruby_rails", concepts: [], level: "strong") }
          .to raise_error(KeyError)
      end
    end

    it "keeps every language-independent vocabulary disjoint from the others, since the prompt merges rungs by concept name" do
      independent = ConceptBucket::LANGUAGE_INDEPENDENT

      DailyExercise::LANGUAGES.each do |language|
        independent.each do |bucket|
          expect(ConceptBucket.vocabulary_for(language) & ConceptBucket.vocabulary_for(bucket)).to be_empty
        end
      end
      independent.combination(2).each do |a, b|
        expect(ConceptBucket.vocabulary_for(a) & ConceptBucket.vocabulary_for(b)).to be_empty
      end
    end
  end
end
