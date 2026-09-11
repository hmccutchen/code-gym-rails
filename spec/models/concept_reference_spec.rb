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

      expect(ConceptReference.featured.featured_on).to eq(Date.current)
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

      expect(ConceptReference.featured(Date.current + 1)).not_to eq(today)
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

    # The two halves of the same-day race guard: the database refuses the
    # loser's stamp (pinned below, against the index itself), and .featured
    # turns that refusal into the winner's pick rather than an exception. Real
    # threads were tried here and could not discriminate — the window between
    # the read and the stamp is a few microseconds wide, so the test passed
    # with the unique index dropped, which is worse than no test.
    it "hands back the winner's pick when its own stamp loses the race" do
      featurable("caching_strategy")
      winner = featurable("idempotency_at_scale")

      allow_any_instance_of(ConceptReference).to receive(:update!) do
        winner.update_column(:featured_on, Date.current)
        raise ActiveRecord::RecordNotUnique, "featured_on"
      end

      expect(ConceptReference.featured).to eq(winner)
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
