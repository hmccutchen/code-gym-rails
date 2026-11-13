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

  describe "ownership" do
    let(:owner) { User.create!(email: "owner@example.com") }
    let(:other) { User.create!(email: "other@example.com") }

    it "lets each user and the shared row hold the same concept and language" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails")
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", user: owner)

      expect(ConceptReference.new(concept: "n_plus_one", language: "ruby_rails", user: other)).to be_valid
      expect(ConceptReference.new(concept: "n_plus_one", language: "ruby_rails", user: owner)).not_to be_valid
      expect(ConceptReference.new(concept: "n_plus_one", language: "ruby_rails")).not_to be_valid
    end

    it "gives a user their own row over the shared one, and the shared one when they have none" do
      shared = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "shared")
      own = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "own", user: owner)

      expect(ConceptReference.for(owner, concept: "n_plus_one", language: "ruby_rails")).to eq(own)
      expect(ConceptReference.for(other, concept: "n_plus_one", language: "ruby_rails")).to eq(shared)
    end

    it "never gives one user another user's row" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", user: owner)

      expect(ConceptReference.for(other, concept: "n_plus_one", language: "ruby_rails")).to be_nil
      expect(ConceptReference.visible_to(other)).to be_empty
    end

    it "indexes the rows a user sees by concept and language, own rows first" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "shared")
      own = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "own", user: owner)
      shared_only = ConceptReference.create!(concept: "caching", language: "ruby_rails")
      ConceptReference.create!(concept: "memoization", language: "ruby_rails", user: other)

      seen = ConceptReference.seen_by(owner, language: "ruby_rails")

      expect(seen).to eq([ "n_plus_one", "ruby_rails" ] => own, [ "caching", "ruby_rails" ] => shared_only)
    end
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
      expect(ConceptReference::LADDER_FIELDS).to eq(KindDifficulty::LEVELS.map { |level| "ladder_#{level}" })
      expect(ConceptReference.column_names).to include(*ConceptReference::LADDER_FIELDS)
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

    it "counts a stored lesson only when it has a part the page can show" do
      row = reference(**full_ladder)

      [ "None", 42, [ "definition" ], {}, { "situations" => "not a list" } ].each do |stored|
        row.lesson = stored
        expect(row).not_to be_lesson, "counted #{stored.inspect} as a lesson"
        expect(row.usable_lesson).to be_nil
        expect(row).not_to be_fully_written
      end
    end

    it "hands the page the stored lesson with unusable parts dropped" do
      row = reference(lesson: { "definition" => "d", "situations" => "not a list", "habits" => [ { "habit" => "h" } ] })

      expect(row).to be_lesson
      expect(row.usable_lesson).to eq("definition" => "d")
    end

    it "defaults historical rows to no completed generation and keeps unrelated updates out of the counter" do
      row = reference(**full_ladder)
      expect(row.generation_version).to eq(0)

      row.update!(ladder_senior: "changed")
      row.update!(explanation: "rewritten")

      expect(row.reload.generation_version).to eq(0)
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
