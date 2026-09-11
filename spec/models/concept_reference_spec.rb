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

    it "is nil when nothing has been written up yet" do
      expect(ConceptReference.featured).to be_nil
    end

    it "picks a never-featured concept ahead of one featured long ago" do
      featurable("caching_strategy", featured_on: 5.days.ago.to_date)
      never = featurable("idempotency_at_scale")

      expect(ConceptReference.featured).to eq(never)
    end

    it "picks the longest-unfeatured concept once every one has had a turn" do
      stalest = featurable("caching_strategy", featured_on: 9.days.ago.to_date)
      featurable("idempotency_at_scale", featured_on: 2.days.ago.to_date)

      expect(ConceptReference.featured).to eq(stalest)
    end

    it "stamps the pick with the date it was asked about" do
      featurable("idempotency_at_scale")

      expect(ConceptReference.featured(Date.new(2026, 3, 4)).featured_on).to eq(Date.new(2026, 3, 4))
    end

    it "returns the same concept on every later visit that day" do
      featurable("idempotency_at_scale")
      featurable("caching_strategy")

      expect(ConceptReference.featured).to eq(ConceptReference.featured)
    end

    it "moves on to another concept the next day" do
      featurable("idempotency_at_scale")
      featurable("caching_strategy")
      today = ConceptReference.featured

      expect(ConceptReference.featured(ConceptReference.team_today + 1)).not_to eq(today)
    end

    # Weekends are not a case the picker knows about — the date it is asked
    # about is its only input — so this pins that nothing weekday-shaped crept
    # in the way it has to elsewhere in this app.
    it "picks on a weekend exactly as on a weekday" do
      featurable("idempotency_at_scale")
      saturday = Date.new(2026, 9, 12)

      expect(ConceptReference.featured(saturday)&.featured_on).to eq(saturday)
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

    # The same-day race, driven through a REAL unique violation rather than a
    # stubbed exception: only the initial read is faked, to open the window a
    # concurrent visit would open. The stamp then genuinely collides with the
    # winner's row, and the recovery read is a genuine query.
    #
    # Real threads were tried here first and could not discriminate: the window
    # between the read and the stamp is microseconds wide, so the test passed
    # with the unique index dropped, which is worse than no test.
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
      winner = featurable("idempotency_at_scale", featured_on: ConceptReference.team_today)

      losing_the_race { expect(ConceptReference.featured).to eq(winner) }
    end

    # The SAVEPOINT, which the example above cannot reach: under transactional
    # specs Rails opens its wrapper NON-joinable, so update!'s own transaction
    # becomes a savepoint on its own and masks the bug. A caller's ordinary
    # transaction is joinable, update! joins it, and without requires_new the
    # collision aborts that transaction — the recovery read then dies of
    # PG::InFailedSqlTransaction instead of returning the winner. No caller
    # opens one today; this pins the guard before one does.
    it "recovers from the collision inside a caller's own transaction" do
      featurable("caching_strategy")
      winner = featurable("idempotency_at_scale", featured_on: ConceptReference.team_today)

      losing_the_race do
        expect(ConceptReference.transaction { ConceptReference.featured }).to eq(winner)
      end
    end

    # ApplicationController runs every action inside the viewer's own zone, so a
    # date resolved there would differ between teammates across midnight and
    # each would stamp their own concept. Driven at an instant where the team
    # zone and the viewer's zone genuinely disagree about the date.
    it "resolves the day in the team's zone, not the viewer's" do
      reference = featurable("idempotency_at_scale")

      # 03:00 UTC on the 12th is still the 11th in America/New_York.
      travel_to Time.utc(2026, 9, 12, 3, 0, 0) do
        Time.use_zone("Asia/Tokyo") { ConceptReference.featured }
      end

      expect(reference.reload.featured_on).to eq(Date.new(2026, 9, 11))
    end

    it "gives two teammates in different zones the same concept" do
      featurable("idempotency_at_scale")
      featurable("caching_strategy")

      travel_to Time.utc(2026, 9, 12, 3, 0, 0) do
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
end
