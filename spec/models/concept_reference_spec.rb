require "rails_helper"

RSpec.describe ConceptReference do
  let(:owner) { User.create!(email: "owner@example.com") }
  let(:other) { User.create!(email: "other@example.com") }

  it "is valid with an owner, a concept and a language" do
    ref = ConceptReference.new(user: owner, concept: "n_plus_one", language: "ruby_rails")
    expect(ref).to be_valid
  end

  it "requires an owner, in the model and in the database" do
    ref = ConceptReference.new(concept: "n_plus_one", language: "ruby_rails")
    expect(ref).not_to be_valid
    expect { ref.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "requires a concept" do
    ref = ConceptReference.new(user: owner, concept: nil, language: "ruby_rails")
    expect(ref).not_to be_valid
  end

  it "requires a language" do
    ref = ConceptReference.new(user: owner, concept: "n_plus_one", language: nil)
    expect(ref).not_to be_valid
  end

  it "allows the same concept in different languages" do
    ConceptReference.create!(user: owner, concept: "closures", language: "javascript")
    ref = ConceptReference.new(user: owner, concept: "closures", language: "ruby_rails")
    expect(ref).to be_valid
  end

  it "rejects a duplicate concept+language for one user at the model level" do
    ConceptReference.create!(user: owner, concept: "n_plus_one", language: "ruby_rails")
    ref = ConceptReference.new(user: owner, concept: "n_plus_one", language: "ruby_rails")
    expect(ref).not_to be_valid
  end

  it "enforces uniqueness at the database level" do
    ConceptReference.create!(user: owner, concept: "n_plus_one", language: "ruby_rails")
    dup = ConceptReference.new(user: owner, concept: "n_plus_one", language: "ruby_rails")
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe "ownership" do
    it "lets each user hold the same concept and language once" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", user: owner)

      expect(ConceptReference.new(concept: "n_plus_one", language: "ruby_rails", user: other)).to be_valid
      expect(ConceptReference.new(concept: "n_plus_one", language: "ruby_rails", user: owner)).not_to be_valid
    end

    it "never gives one user another user's row" do
      own = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", user: owner)

      expect(owner.concept_references.find_by(concept: "n_plus_one", language: "ruby_rails")).to eq(own)
      expect(other.concept_references.find_by(concept: "n_plus_one", language: "ruby_rails")).to be_nil
      expect(other.concept_references).to be_empty
    end

    it "indexes the user's own rows by concept and language, leaving out other users' rows" do
      own = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "own", user: owner)
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "theirs", user: other)
      ConceptReference.create!(concept: "memoization", language: "ruby_rails", user: other)

      owned = ConceptReference.indexed_for(owner, language: "ruby_rails")

      expect(owned).to eq([ "n_plus_one", "ruby_rails" ] => own)
    end

    it "lists the pairs a user has no reference of their own for, in the order given" do
      ConceptReference.create!(concept: "caching", language: "ruby_rails", user: other)
      ConceptReference.create!(concept: "closures", language: "javascript", user: owner)
      pairs = [ [ "n_plus_one", "ruby_rails" ], [ "caching", "ruby_rails" ], [ "closures", "javascript" ], [ "memoization", "ruby_rails" ] ]

      expect(ConceptReference.missing_for(owner, pairs))
        .to eq([ [ "n_plus_one", "ruby_rails" ], [ "caching", "ruby_rails" ], [ "memoization", "ruby_rails" ] ])
      expect(ConceptReference.missing_for(owner, [])).to eq([])
    end

    it "counts any user's row as a concept written up, for the admin promote check" do
      ConceptReference.create!(concept: "circuit_breaker", language: "ruby_rails", user: other)
      ConceptReference.create!(concept: "debounce", language: "javascript", user: owner)

      expect(ConceptReference.written_up?(language: "ruby_rails", concept: "circuit_breaker")).to be(true)
      expect(ConceptReference.written_up?(language: "javascript", concept: "circuit_breaker")).to be(false)
      expect(ConceptReference.written_up_keys(languages: [ "ruby_rails", "javascript" ]))
        .to eq(Set[[ "ruby_rails", "circuit_breaker" ], [ "javascript", "debounce" ]])
      expect(ConceptReference.written_up_keys(languages: [ "javascript" ])).to eq(Set[[ "javascript", "debounce" ]])
    end
  end

  it "lists every field a write-up fills: the reference, guide, ladder and lesson" do
    expect(ConceptReference::WRITTEN_FIELDS).to eq(
      ConceptReference::REFERENCE_FIELDS + ConceptReference::GUIDE_FIELDS + ConceptReference::LADDER_FIELDS + [ "lesson" ]
    )
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
      ConceptReference.create!({ user: owner, concept: "n_plus_one", language: "ruby_rails",
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

  describe ".write_for" do
    let(:reply) { { "tagline" => "new tagline", "explanation" => "new", "guide_plain_language" => "p" } }

    def write(user = owner, refresh: false, seen_version: nil)
      described_class.write_for(user, concept: "n_plus_one", language: "ruby_rails", attributes: reply,
                                      refresh: refresh, seen_version: seen_version)
    end

    def own_row(version: 0, **fields)
      described_class.create!(fields.merge(user: owner, concept: "n_plus_one", language: "ruby_rails", generation_version: version))
    end

    def locks_taken(&)
      statements = []
      subscriber = ->(*, payload) { statements << payload[:sql] if payload[:sql].match?(/FOR (SHARE|UPDATE)/) }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &)
      statements.map { |sql| "#{sql[/FROM "(\w+)"/, 1]} #{sql[/FOR (SHARE|UPDATE)/]}" }
    end

    it "creates the user's own row at version 1 from the reply's written fields, leaving the rest blank" do
      expect(write).to eq(:written)

      row = described_class.sole
      expect([ row.user, row.tagline, row.generation_version, row.ladder_junior ]).to eq([ owner, "new tagline", 1, nil ])
    end

    it "writes nothing for an account deleted before the write" do
      User.where(id: owner.id).delete_all

      expect(write).to eq(:account_deleted)
      expect(described_class.count).to eq(0)
    end

    it "writes nothing for an anonymized account" do
      owner.update_columns(anonymized_at: Time.current)

      expect(write).to eq(:account_deleted)
      expect(described_class.count).to eq(0)
    end

    it "share-locks the owner before it inserts" do
      expect(locks_taken { write }).to eq([ "users FOR SHARE" ])
    end

    it "share-locks the owner before it locks the row it rewrites" do
      own_row(tagline: "old")

      expect(locks_taken { write(refresh: true) }).to eq([ "users FOR SHARE", "concept_references FOR UPDATE" ])
    end

    it "rewrites an incomplete row on a refresh, replacing every written field and advancing its version" do
      row = own_row(version: 2, tagline: "old", ladder_junior: "j")

      expect(write(refresh: true, seen_version: 2)).to eq(:written)
      expect([ row.reload.tagline, row.ladder_junior, row.generation_version ]).to eq([ "new tagline", nil, 3 ])
    end

    it "advances from the row's current version when a refresh names none" do
      row = own_row(version: 1, tagline: "old")

      expect(write(refresh: true)).to eq(:written)
      expect(row.reload.generation_version).to eq(2)
    end

    it "leaves a row it did not see alone on a plain write-up" do
      row = own_row(version: 1, tagline: "added meanwhile")

      expect(write).to eq(:skipped)
      expect([ row.reload.tagline, row.generation_version ]).to eq([ "added meanwhile", 1 ])
    end

    it "leaves a row alone on a refresh asked for against another version" do
      row = own_row(version: 1, tagline: "added meanwhile")

      expect(write(refresh: true, seen_version: 0)).to eq(:skipped)
      expect(row.reload.generation_version).to eq(1)
    end

    it "leaves a fully written row alone even on a refresh" do
      row = own_row(tagline: "kept", guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x",
                    ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p",
                    lesson: { "definition" => "d" })

      expect(write(refresh: true)).to eq(:skipped)
      expect([ row.reload.tagline, row.generation_version ]).to eq([ "kept", 0 ])
    end

    it "asks again under the row lock, so a row fully written after the read is left alone" do
      row = own_row(tagline: "old")
      allow_any_instance_of(described_class).to receive(:with_lock) do |record, &block|
        record.update!(guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "x",
                       ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p",
                       lesson: { "definition" => "winner" }, generation_version: 1)
        block.call
      end

      expect(write(refresh: true)).to eq(:skipped)
      expect([ row.reload.tagline, row.generation_version ]).to eq([ "old", 1 ])
    end

    it "writes nothing when a refresh asked against a row that has since gone" do
      expect(write(refresh: true, seen_version: 2)).to eq(:skipped)
      expect(described_class.count).to eq(0)
    end

    it "creates the row on a refresh asked when the user saw none" do
      expect(write(refresh: true, seen_version: 0)).to eq(:written)
      expect(described_class.sole.generation_version).to eq(1)
    end

    it "reads the user's own row past the caller's query cache" do
      cached_reads = []
      subscriber = ->(*, payload) { cached_reads << payload[:sql] if payload[:cached] && payload[:sql].include?("concept_references") }

      described_class.cache do
        owner.concept_references.find_by(concept: "n_plus_one", language: "ruby_rails")
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { write }
      end

      expect(cached_reads).to be_empty
    end

    it "is written for a user with only another user's row" do
      described_class.create!(user: other, concept: "n_plus_one", language: "ruby_rails", tagline: "theirs")

      expect(write).to eq(:written)
      expect(described_class.find_by!(user: other).tagline).to eq("theirs")
    end
  end

  describe ".write_ladder_for" do
    let(:ladder) { described_class::LADDER_FIELDS.index_with { |field| "new #{field}" } }

    def write_ladder(user = owner, seen_version: 2)
      described_class.write_ladder_for(user, concept: "n_plus_one", language: "ruby_rails", ladder: ladder, seen_version: seen_version)
    end

    def own_row(version: 2, **fields)
      described_class.create!({ tagline: "kept tagline", explanation: "kept explanation", code_example: "kept code",
                                senior_lens: "kept lens", guide_plain_language: "p", guide_worked_example: "w",
                                guide_pitfalls: "x", lesson: { "definition" => "kept" } }
                                .merge(fields, user: owner, concept: "n_plus_one", language: "ruby_rails", generation_version: version))
    end

    def locks_taken(&)
      statements = []
      subscriber = ->(*, payload) { statements << payload[:sql] if payload[:sql].match?(/FOR (SHARE|UPDATE)/) }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &)
      statements.map { |sql| "#{sql[/FROM "(\w+)"/, 1]} #{sql[/FOR (SHARE|UPDATE)/]}" }
    end

    it "writes only the ladder, keeping every other field as it was, and advances the version" do
      row = own_row
      before = row.attributes.except(*described_class::LADDER_FIELDS, "generation_version", "updated_at")

      expect(write_ladder).to eq(:written)
      row.reload
      expect(row.attributes.except(*described_class::LADDER_FIELDS, "generation_version", "updated_at")).to eq(before)
      expect(described_class::LADDER_FIELDS.map { |field| row.public_send(field) }).to eq(ladder.values)
      expect(row.generation_version).to eq(3)
    end

    it "writes nothing for an account deleted before the write" do
      row = own_row
      owner.update_columns(anonymized_at: Time.current)

      expect(write_ladder).to eq(:account_deleted)
      expect([ row.reload.ladder_junior, row.generation_version ]).to eq([ nil, 2 ])
    end

    it "share-locks the owner before it locks the row" do
      own_row

      expect(locks_taken { write_ladder }).to eq([ "users FOR SHARE", "concept_references FOR UPDATE" ])
    end

    it "leaves the row alone when it was asked for against another version" do
      row = own_row(version: 3)

      expect(write_ladder(seen_version: 2)).to eq(:skipped)
      expect([ row.reload.ladder_junior, row.generation_version ]).to eq([ nil, 3 ])
    end

    it "leaves a row that already has a ladder alone" do
      row = own_row(ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")

      expect(write_ladder).to eq(:skipped)
      expect([ row.reload.ladder_junior, row.generation_version ]).to eq([ "j", 2 ])
    end

    it "asks again under the row lock, so a ladder written after the read is left alone" do
      row = own_row
      allow_any_instance_of(described_class).to receive(:with_lock) do |record, &block|
        record.update!(ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p",
                       generation_version: 3)
        block.call
      end

      expect(write_ladder(seen_version: nil)).to eq(:skipped)
      expect([ row.reload.ladder_junior, row.generation_version ]).to eq([ "j", 3 ])
    end

    it "writes nothing when the row has gone" do
      expect(write_ladder).to eq(:skipped)
      expect(described_class.count).to eq(0)
    end

    it "never writes another user's row" do
      theirs = described_class.create!(user: other, concept: "n_plus_one", language: "ruby_rails", tagline: "theirs",
                                       explanation: "theirs", generation_version: 2)

      expect(write_ladder).to eq(:skipped)
      expect(theirs.reload.ladder_junior).to be_nil
    end
  end

  describe ".ladder_wanted?" do
    let(:written) { described_class.new(tagline: "t", explanation: "e", code_example: "c", senior_lens: "s", generation_version: 2) }

    it "wants a ladder for a written-up row without one, against its version or naming none" do
      expect(described_class.ladder_wanted?(written, seen_version: 2)).to be(true)
      expect(described_class.ladder_wanted?(written, seen_version: nil)).to be(true)
      expect(described_class.ladder_wanted?(written, seen_version: 1)).to be(false)
    end

    it "wants none for a missing row, a row with no reference text or a row that has a ladder" do
      laddered = written.dup.tap { |row| described_class::LADDER_FIELDS.each { |field| row[field] = "rung" } }

      expect(described_class.ladder_wanted?(nil, seen_version: nil)).to be(false)
      expect(described_class.ladder_wanted?(described_class.new(generation_version: 2), seen_version: 2)).to be(false)
      expect(described_class.ladder_wanted?(laddered, seen_version: 2)).to be(false)
    end
  end

  describe ".write_wanted?" do
    let(:incomplete) { described_class.new(generation_version: 2) }

    it "wants a first write when the user has no row and saw none" do
      expect(described_class.write_wanted?(nil, refresh: false, seen_version: nil)).to be(true)
      expect(described_class.write_wanted?(nil, refresh: true, seen_version: 0)).to be(true)
    end

    it "wants a rewrite of an incomplete row only on a refresh against its version, or naming none" do
      expect(described_class.write_wanted?(incomplete, refresh: false, seen_version: nil)).to be(false)
      expect(described_class.write_wanted?(incomplete, refresh: true, seen_version: 2)).to be(true)
      expect(described_class.write_wanted?(incomplete, refresh: true, seen_version: nil)).to be(true)
      expect(described_class.write_wanted?(incomplete, refresh: true, seen_version: 1)).to be(false)
    end

    it "wants no first write when the request names a version the missing row no longer has" do
      expect(described_class.write_wanted?(nil, refresh: true, seen_version: 1)).to be(false)
    end
  end
end
