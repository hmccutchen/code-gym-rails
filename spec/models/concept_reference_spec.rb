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

  describe ".featured" do
    def featurable(concept, featured_on: nil)
      ConceptReference.create!(concept: concept, language: "architecture", featured_on: featured_on)
    end

    def this_week = ConceptReference.featured_week_of(ConceptReference.team_today)

    it "is nil when nothing has been written up yet" do
      expect(ConceptReference.featured).to be_nil
    end

    it "picks a never-featured concept ahead of one featured long ago" do
      featurable("caching_strategy", featured_on: this_week - 7)
      never = featurable("idempotency_at_scale")

      expect(ConceptReference.featured).to eq(never)
    end

    it "picks the longest-unfeatured concept once every one has had a turn" do
      stalest = featurable("caching_strategy", featured_on: this_week - 14)
      featurable("idempotency_at_scale", featured_on: this_week - 7)

      expect(ConceptReference.featured).to eq(stalest)
    end

    it "stamps the pick with the Monday of the week it was asked about" do
      featurable("idempotency_at_scale")
      wednesday = Date.new(2026, 3, 4)

      expect(ConceptReference.featured(wednesday).featured_on).to eq(Date.new(2026, 3, 2))
    end

    it "keeps one concept from Monday through Sunday" do
      featurable("idempotency_at_scale")
      featurable("caching_strategy")
      monday = Date.new(2026, 9, 7)
      picked = ConceptReference.featured(monday)

      expect((monday..monday + 6).map { |day| ConceptReference.featured(day) }).to all(eq(picked))
    end

    it "moves on to another concept the next Monday" do
      featurable("idempotency_at_scale")
      featurable("caching_strategy")
      sunday = Date.new(2026, 9, 13)
      this_week = ConceptReference.featured(sunday)

      expect(ConceptReference.featured(sunday + 1)).not_to eq(this_week)
    end

    # The date asked about is the picker's only input, so a Saturday visit picks for the week begun Monday.
    it "picks on a weekend for the week it belongs to" do
      featurable("idempotency_at_scale")
      saturday = Date.new(2026, 9, 12)

      expect(ConceptReference.featured(saturday)&.featured_on).to eq(Date.new(2026, 9, 7))
    end

    # Rows featured while the pick was daily carry any weekday; a Monday stamp is that week's pick.
    it "takes a daily pick stamped on this week's Monday as the week's concept" do
      featurable("caching_strategy")
      monday_pick = featurable("idempotency_at_scale", featured_on: Date.new(2026, 9, 7))

      expect(ConceptReference.featured(Date.new(2026, 9, 9))).to eq(monday_pick)
    end

    it "ignores a language vocabulary, which not every user can reach" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails")

      expect(ConceptReference.featured).to be_nil
    end

    it "features a row whose guide was never written, leaving its page to offer one" do
      reference = featurable("idempotency_at_scale")

      expect(ConceptReference.featured).to eq(reference)
      expect(reference).not_to be_guide
    end

    # Real threads passed with the unique index dropped, so only the read is faked to force a real collision.
    def losing_the_race
      missed_once = false

      allow(ConceptReference).to receive(:find_by).and_wrap_original do |original, *args|
        next original.call(*args) if missed_once

        missed_once = true
        nil
      end

      yield
    end

    it "hands back the winner's pick when its own stamp loses the race" do
      featurable("caching_strategy")
      winner = featurable("idempotency_at_scale", featured_on: this_week)

      losing_the_race { expect(ConceptReference.featured).to eq(winner) }
    end

    # Transactional specs open a non-joinable wrapper, which masks a missing requires_new; a caller's does not.
    it "recovers from the collision inside a caller's own transaction" do
      featurable("caching_strategy")
      winner = featurable("idempotency_at_scale", featured_on: this_week)

      losing_the_race do
        expect(ConceptReference.transaction { ConceptReference.featured }).to eq(winner)
      end
    end

    # A week resolved in each viewer's zone would let teammates stamp different concepts across Sunday midnight.
    it "resolves the week in the team's zone, not the viewer's" do
      reference = featurable("idempotency_at_scale")

      # 03:00 UTC Monday the 14th is still Sunday in America/New_York, so the team's week began on the 7th.
      travel_to Time.utc(2026, 9, 14, 3, 0, 0) do
        Time.use_zone("Asia/Tokyo") { ConceptReference.featured }
      end

      expect(reference.reload.featured_on).to eq(Date.new(2026, 9, 7))
    end

    it "gives two teammates in different zones the same concept" do
      featurable("idempotency_at_scale")
      featurable("caching_strategy")

      travel_to Time.utc(2026, 9, 14, 3, 0, 0) do
        tokyo    = Time.use_zone("Asia/Tokyo") { ConceptReference.featured }
        honolulu = Time.use_zone("Pacific/Honolulu") { ConceptReference.featured }

        expect(tokyo).to eq(honolulu)
      end
    end

    it "spends nothing to pick" do
      featurable("idempotency_at_scale")

      expect { ConceptReference.featured }.not_to change(ApiUsage, :count)
    end
  end

  it "refuses a second concept stamped for the same day at the database level" do
    ConceptReference.create!(concept: "idempotency_at_scale", language: "architecture", featured_on: Date.current)
    second = ConceptReference.new(concept: "caching_strategy", language: "architecture", featured_on: Date.current)

    expect { second.save! }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "lets every never-featured row sit unstamped together" do
    ConceptReference.create!(concept: "idempotency_at_scale", language: "architecture")

    expect { ConceptReference.create!(concept: "caching_strategy", language: "architecture") }.not_to raise_error
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

    let(:full_ladder) { { ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "p" } }

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

      row.update!(ladder_senior: "changed", featured_on: Date.current)
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

    # The prompt merges rungs by concept name, which is safe only while no name lives in two buckets a day holds.
    it "keeps every language-independent vocabulary disjoint from the others" do
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
