require "rails_helper"

# Pure over response objects: examples build rows in memory and never touch the database.
RSpec.describe RungLedger do
  include ActiveSupport::Testing::TimeHelpers

  def response_on(date, language: "ruby_rails", sections: {})
    problem_set = sections.transform_values { |s| { "concept" => s[:concept], "pitched_at" => s[:rung], "eased" => s[:eased] }.compact }
    exercise = DailyExercise.new(date: date, language: language, problem_set: problem_set, generated_at: Time.current)
    DailyResponse.new(
      daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: sections.transform_values { |s| s.fetch(:answered, true) ? "x" * 20 : "" },
      concept_tags: sections.transform_values { |s| s[:concept] },
      section_ratings: sections.transform_values { |s| s.fetch(:self, "right_level") },
      ai_review: sections.filter_map { |key, s|
        next if s[:unreviewed]
        rating = s.key?(:ai) ? s[:ai] : "solid"
        [ key, rating ? { "rating" => rating, "correct" => "c" } : { "correct" => "c" } ]
      }.to_h
    )
  end

  def ledger(*responses) = described_class.new(responses)

  it "holds a rung from a co-favourable attempt at it" do
    held = ledger(response_on(Date.current, sections: { "code_review" => { concept: "n_plus_one", rung: "senior" } }))

    expect(held.held("n_plus_one", "ruby_rails")).to eq("senior")
  end

  it "holds nothing from an attempt either signal found unfavourable" do
    self_bad = ledger(response_on(Date.current, sections: { "code_review" => { concept: "n_plus_one", rung: "senior", self: "too_hard" } }))
    ai_bad   = ledger(response_on(Date.current, sections: { "code_review" => { concept: "n_plus_one", rung: "senior", ai: "developing" } }))

    expect(self_bad.held("n_plus_one", "ruby_rails")).to be_nil
    expect(ai_bad.held("n_plus_one", "ruby_rails")).to be_nil
  end

  describe "#developing_toward" do
    it "names the lowest rung when an attempt held nothing" do
      led = ledger(response_on(Date.current, sections: { "code_review" => { concept: "n_plus_one", rung: "senior", ai: "developing" } }))

      expect(led.developing_toward("n_plus_one", "ruby_rails")).to eq("junior")
    end

    it "names the rung just above the held one when a higher rung has been attempted" do
      led = ledger(
        response_on(Date.current,     sections: { "code_review" => { concept: "n_plus_one", rung: "principal_engineer", ai: "beginner" } }),
        response_on(Date.current - 1, sections: { "code_review" => { concept: "n_plus_one", rung: "junior" } })
      )

      expect(led.held("n_plus_one", "ruby_rails")).to eq("junior")
      expect(led.developing_toward("n_plus_one", "ruby_rails")).to eq("senior")
    end

    it "is nil with nothing attempted above the held rung, or nothing attempted at all" do
      held_only = ledger(response_on(Date.current, sections: { "code_review" => { concept: "n_plus_one", rung: "senior" } }))
      led_low = ledger(
        response_on(Date.current,     sections: { "code_review" => { concept: "n_plus_one", rung: "junior", ai: "developing" } }),
        response_on(Date.current - 1, sections: { "code_review" => { concept: "n_plus_one", rung: "senior" } })
      )

      expect(held_only.developing_toward("n_plus_one", "ruby_rails")).to be_nil
      expect(led_low.developing_toward("n_plus_one", "ruby_rails")).to be_nil
      expect(ledger.developing_toward("n_plus_one", "ruby_rails")).to be_nil
    end

    it "is nil at the top rung" do
      led = ledger(response_on(Date.current, sections: { "code_review" => { concept: "n_plus_one", rung: "principal_engineer" } }))

      expect(led.developing_toward("n_plus_one", "ruby_rails")).to be_nil
    end
  end

  it "reads the most recent attempt at a rung, so a later poor one releases it" do
    good_then_bad = ledger(
      response_on(Date.current,     sections: { "code_review" => { concept: "n_plus_one", rung: "senior", ai: "developing" } }),
      response_on(Date.current - 3, sections: { "code_review" => { concept: "n_plus_one", rung: "senior" } })
    )

    expect(good_then_bad.held("n_plus_one", "ruby_rails")).to be_nil
  end

  it "answers the highest held rung, which covers the rungs below it" do
    mixed = ledger(
      response_on(Date.current,     sections: { "code_review" => { concept: "n_plus_one", rung: "junior", ai: "developing" } }),
      response_on(Date.current - 2, sections: { "code_review" => { concept: "n_plus_one", rung: "principal_engineer" } })
    )

    expect(mixed.held("n_plus_one", "ruby_rails")).to eq("principal_engineer")
  end

  it "counts neither an eased, a skipped, an unreviewed nor an unstamped section as an attempt" do
    none = ledger(
      response_on(Date.current,     sections: { "code_review" => { concept: "n_plus_one", rung: "senior", eased: true } }),
      response_on(Date.current - 1, sections: { "code_review" => { concept: "n_plus_one", rung: "senior", answered: false } }),
      response_on(Date.current - 2, sections: { "code_review" => { concept: "n_plus_one", rung: "senior", unreviewed: true } }),
      response_on(Date.current - 3, sections: { "code_review" => { concept: "n_plus_one" } })
    )

    expect(none.held("n_plus_one", "ruby_rails")).to be_nil
  end

  # A rung is held on record_review!'s terms: the least favourable section that day decides.
  it "judges a concept tagged on two sections of one day by the least favourable section" do
    split = ledger(response_on(Date.current, sections: {
      "code_review" => { concept: "n_plus_one", rung: "senior" },
      "pattern"     => { concept: "n_plus_one", rung: "senior", ai: "developing" }
    }))

    expect(split.held("n_plus_one", "ruby_rails")).to be_nil
  end

  # A review with no rating is no signal, as in record_review!; it neither holds nor releases.
  it "treats a reviewed section with no rating as no attempt, leaving an earlier verdict standing" do
    unrated = ledger(
      response_on(Date.current,     sections: { "code_review" => { concept: "n_plus_one", rung: "senior", ai: nil } }),
      response_on(Date.current - 2, sections: { "code_review" => { concept: "n_plus_one", rung: "senior" } })
    )

    expect(unrated.held("n_plus_one", "ruby_rails")).to eq("senior")
  end

  it "keeps a shared concept name apart by bucket" do
    both = ledger(
      response_on(Date.current,     language: "javascript", sections: { "code_review" => { concept: "over_mocking", rung: "senior", ai: "developing" } }),
      response_on(Date.current - 1, language: "ruby_rails", sections: { "code_review" => { concept: "over_mocking", rung: "senior" } })
    )

    expect(both.held("over_mocking", "javascript")).to be_nil
    expect(both.held("over_mocking", "ruby_rails")).to eq("senior")
  end

  it "does not move with time: nothing is compared to today" do
    rows = [ response_on(Date.current, sections: { "code_review" => { concept: "n_plus_one", rung: "senior" } }) ]
    before = ledger(*rows).held("n_plus_one", "ruby_rails")

    travel_to(90.days.from_now) { expect(ledger(*rows).held("n_plus_one", "ruby_rails")).to eq(before) }
  end
end
