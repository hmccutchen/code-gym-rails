require "rails_helper"

RSpec.describe BugHuntGotchas do
  describe "the registry" do
    it "holds 11 Ruby entries and 12 JavaScript entries" do
      expect(described_class.for_language("ruby_rails").size).to eq(11)
      expect(described_class.for_language("javascript").size).to eq(12)
    end

    it "tags every entry with a concept from its own language's vocabulary" do
      described_class::BY_LANGUAGE.each do |language, entries|
        expect(entries.map(&:concept) - ConceptVocabulary.for_language(language)).to be_empty
      end
    end

    it "gives every entry a unique id prefixed by its language" do
      ids = described_class.all.map(&:id)

      expect(ids.uniq).to eq(ids)
      expect(described_class.for_language("ruby_rails").map(&:id)).to all(start_with("rb_"))
      expect(described_class.for_language("javascript").map(&:id)).to all(start_with("js_"))
    end

    it "gives every entry a one-line rule" do
      expect(described_class.all.map(&:rule)).to all(be_present)
      expect(described_class.all.map(&:rule)).to all(satisfy { |rule| !rule.include?("\n") })
    end

    it "writes every JavaScript rule for an ES module, never for CommonJS" do
      rules = described_class.for_language("javascript").map(&:rule).join("\n")

      expect(rules).not_to include("require(", "module.exports")
    end

    it "never plants a Ruby default argument, which Ruby builds fresh on every call" do
      expect(described_class.for_language("ruby_rails").map(&:rule).join("\n")).not_to match(/default argument/i)
    end

    it "raises on a language with no registry" do
      expect { described_class.for_language("architecture") }.to raise_error(ConceptVocabulary::UnknownLanguage)
    end
  end

  describe ".concepts" do
    it "lists each language's concepts once, in registry order" do
      concepts = described_class.concepts("javascript")

      expect(concepts).to eq(concepts.uniq)
      expect(concepts.first).to eq(described_class.for_language("javascript").first.concept)
    end
  end

  describe ".find" do
    it "finds an entry by id and returns nil for an id the registry no longer holds" do
      expect(described_class.find("rb_memo_falsy").concept).to eq("memoization")
      expect(described_class.find("rb_cut_long_ago")).to be_nil
    end
  end

  describe ".pick" do
    let(:entries) { described_class.for_language("ruby_rails") }

    it "picks the first entry when nothing has been seen" do
      expect(described_class.pick("ruby_rails", last_seen: {})).to eq(entries.first)
    end

    it "picks the first never-seen entry in list order" do
      seen = { entries[0].id => Date.current - 1, entries[1].id => Date.current - 2 }

      expect(described_class.pick("ruby_rails", last_seen: seen)).to eq(entries[2])
    end

    it "picks the one seen longest ago once every entry has been seen" do
      seen = entries.each_with_index.to_h { |entry, index| [ entry.id, Date.current - index ] }

      expect(described_class.pick("ruby_rails", last_seen: seen)).to eq(entries.last)
    end

    it "breaks a tie in last-seen date by list order" do
      seen = entries.to_h { |entry| [ entry.id, Date.current - 1 ] }

      expect(described_class.pick("ruby_rails", last_seen: seen)).to eq(entries.first)
    end

    it "ignores a seen id the registry no longer holds" do
      expect(described_class.pick("ruby_rails", last_seen: { "rb_cut_long_ago" => Date.current - 100 })).to eq(entries.first)
    end
  end

  describe ".last_seen_for" do
    let(:user) { User.create!(email: "hunt@example.com", name: "Hunt") }

    def exercise_on(date, gotcha:)
      user.daily_exercises.create!(
        date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "concept" => "memoization" } },
        plan_notes: { "daily_kinds" => [ "code_review" ], "bug_hunt" => gotcha }.compact
      )
    end

    it "reads each picked gotcha's latest date back out of the plan notes" do
      exercise_on(Date.current - 10, gotcha: "rb_memo_falsy")
      exercise_on(Date.current - 3, gotcha: "rb_memo_falsy")
      exercise_on(Date.current - 7, gotcha: "rb_to_i_silent")

      expect(described_class.last_seen_for(user)).to eq("rb_memo_falsy" => Date.current - 3, "rb_to_i_silent" => Date.current - 7)
    end

    it "ignores days that picked no gotcha" do
      exercise_on(Date.current - 1, gotcha: nil)

      expect(described_class.last_seen_for(user)).to eq({})
    end

    it "is scoped to the one user" do
      other = User.create!(email: "other-hunt@example.com", name: "Other")
      other.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                                    problem_set: { "code_review" => {} }, plan_notes: { "bug_hunt" => "rb_memo_falsy" })

      expect(described_class.last_seen_for(user)).to eq({})
    end
  end
end
