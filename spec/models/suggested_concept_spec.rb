require "rails_helper"

RSpec.describe SuggestedConcept do
  describe "validations" do
    it "is valid with a recognized language and default status" do
      concept = SuggestedConcept.new(
        language: "ruby_rails", normalized_name: "foo_bar", display_name: "Foo Bar",
        first_seen_at: Time.current, last_seen_at: Time.current
      )
      expect(concept).to be_valid
    end

    it "rejects an unrecognized language" do
      concept = SuggestedConcept.new(
        language: "cobol", normalized_name: "foo_bar", display_name: "Foo Bar",
        first_seen_at: Time.current, last_seen_at: Time.current
      )
      expect(concept).not_to be_valid
    end

    it "rejects an unrecognized status" do
      concept = SuggestedConcept.new(
        language: "ruby_rails", normalized_name: "foo_bar", display_name: "Foo Bar",
        first_seen_at: Time.current, last_seen_at: Time.current, status: "archived"
      )
      expect(concept).not_to be_valid
    end

    it "requires normalized_name and display_name" do
      concept = SuggestedConcept.new(
        language: "ruby_rails", first_seen_at: Time.current, last_seen_at: Time.current
      )
      expect(concept).not_to be_valid
      expect(concept.errors[:normalized_name]).to be_present
      expect(concept.errors[:display_name]).to be_present
    end
  end

  describe ".record!" do
    it "creates a new row on first sighting, keeping the original casing as display_name" do
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "  N+1 Queries!!  ")

      expect(concept.display_name).to eq("N+1 Queries!!")
      expect(concept.normalized_name).to eq("n+1 queries!!")
      expect(concept.occurrences).to eq(1)
      expect(concept.status).to eq("pending")
      expect(concept.first_seen_at).to be_present
      expect(concept.last_seen_at).to eq(concept.first_seen_at)
    end

    it "increments occurrences and bumps last_seen_at on a repeat, without changing display_name" do
      first = SuggestedConcept.record!(language: "ruby_rails", name: "N+1 Queries!!")

      travel 1.hour do
        second = SuggestedConcept.record!(language: "ruby_rails", name: "n+1   queries!!")

        expect(second.id).to eq(first.id)
        expect(second.occurrences).to eq(2)
        expect(second.display_name).to eq("N+1 Queries!!")
        expect(second.last_seen_at).to be > first.first_seen_at
      end
    end

    it "does not lose an increment when two processes load the row before either writes back" do
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "n+1 queries!!")

      stale_a = SuggestedConcept.find(concept.id)
      stale_b = SuggestedConcept.find(concept.id)
      allow(SuggestedConcept).to receive(:find_or_initialize_by).and_return(stale_a, stale_b)

      SuggestedConcept.record!(language: "ruby_rails", name: "n+1 queries!!")
      SuggestedConcept.record!(language: "ruby_rails", name: "n+1 queries!!")

      expect(concept.reload.occurrences).to eq(3)
    end

    it "treats the same normalized_name in different languages as separate rows" do
      SuggestedConcept.record!(language: "ruby_rails", name: "closures")
      SuggestedConcept.record!(language: "javascript", name: "closures")

      expect(SuggestedConcept.where(normalized_name: "closures").count).to eq(2)
    end

    it "is a no-op for a literal 'other'" do
      result = SuggestedConcept.record!(language: "ruby_rails", name: "other")

      expect(result).to be_nil
      expect(SuggestedConcept.count).to eq(0)
    end

    it "is a no-op for a blank name" do
      expect(SuggestedConcept.record!(language: "ruby_rails", name: "   ")).to be_nil
      expect(SuggestedConcept.count).to eq(0)
    end
  end
end
