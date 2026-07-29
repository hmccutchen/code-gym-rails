require "rails_helper"

RSpec.describe DailyResponse, type: :model do
  describe ".review_points" do
    it "strips entries and drops blanks from an array" do
      expect(DailyResponse.review_points([ "  Spotted the N+1  ", "", "Missed the index", nil ]))
        .to eq([ "Spotted the N+1", "Missed the index" ])
    end

    it "wraps a legacy string in a single-item array" do
      expect(DailyResponse.review_points("One dense paragraph covering several points"))
        .to eq([ "One dense paragraph covering several points" ])
    end

    it "returns an empty array for nil, a blank string, and an empty array" do
      expect(DailyResponse.review_points(nil)).to eq([])
      expect(DailyResponse.review_points("   ")).to eq([])
      expect(DailyResponse.review_points([])).to eq([])
    end

    it "tolerates unexpected non-string, non-array shapes as a one-item array" do
      expect(DailyResponse.review_points({ "a" => "b" })).to eq([ { "a" => "b" }.to_s ])
      expect(DailyResponse.review_points(42)).to eq([ "42" ])
    end
  end

  describe ".improved_code_text" do
    it "preserves a code block's leading indentation, unlike .review_points" do
      code = "def foo\n  bar\nend"
      expect(DailyResponse.improved_code_text(code)).to eq(code)
    end

    it "tolerates the Array shape drift review_points guards against, joined without stripping entries" do
      expect(DailyResponse.improved_code_text([ "  def foo", "  bar", "end" ]))
        .to eq("  def foo\n  bar\nend")
    end

    it "treats nil and blank as absent" do
      expect(DailyResponse.improved_code_text(nil)).to be_nil
      expect(DailyResponse.improved_code_text("")).to be_nil
      expect(DailyResponse.improved_code_text("   ")).to be_nil
      expect(DailyResponse.improved_code_text([])).to be_nil
    end
  end

  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  let(:exercise) do
    user.daily_exercises.create!(
      date: Date.current,
      generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
    )
  end

  describe "#answered_sections" do
    it "returns keys whose answers have substance (>10 chars), preserving the completeness heuristic" do
      daily_response = user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.current,
        answers: { "code_review" => "Found the N+1 in the loop", "pattern" => "short", "challenge" => "" }
      )

      expect(daily_response.answered_sections).to eq([ "code_review" ])
      expect(daily_response.completeness).to eq(33)
    end

    it "does not count whitespace-only answers, however long" do
      daily_response = user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.current,
        answers: { "code_review" => " " * 20 }
      )

      expect(daily_response.answered_sections).to be_empty
    end
  end

  describe "per-section self-rating predicates" do
    def response_with(section_ratings)
      user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
                                   answers: {}, section_ratings: section_ratings)
    end

    it "treats right_level and too_easy as favorable, too_hard as unfavorable" do
      r = response_with("code_review" => "right_level", "pattern" => "too_easy", "challenge" => "too_hard")

      expect(r.self_rating_favorable?("code_review")).to be(true)
      expect(r.self_rating_favorable?("pattern")).to be(true)
      expect(r.self_rating_favorable?("challenge")).to be(false)
      expect(r.self_rating_unfavorable?("challenge")).to be(true)
      expect(r.self_rating_unfavorable?("code_review")).to be(false)
    end

    it "is nil-safe for a section with no rating" do
      r = response_with("code_review" => "right_level")

      expect(r.self_rating_for("pattern")).to be_nil
      expect(r.self_rating_favorable?("pattern")).to be(false)
      expect(r.self_rating_unfavorable?("pattern")).to be(false)
      expect(r.self_rating_label("code_review")).to eq("just right")
    end
  end

  describe "#ai_rating_for, #ai_rating_favorable?, and #ai_rating_unfavorable?" do
    it "reads the per-section rating out of ai_review, nil-safe when unreviewed or the section is missing" do
      reviewed = user.daily_responses.create!(
        daily_exercise: exercise, date: Date.current, answers: {},
        ai_review: { "code_review" => { "rating" => "developing" }, "pattern" => { "rating" => "strong" } }
      )
      unreviewed = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 1, answers: {})

      expect(reviewed.ai_rating_for("code_review")).to eq("developing")
      expect(reviewed.ai_rating_favorable?("code_review")).to be(false)
      expect(reviewed.ai_rating_unfavorable?("code_review")).to be(true)

      expect(reviewed.ai_rating_for("pattern")).to eq("strong")
      expect(reviewed.ai_rating_favorable?("pattern")).to be(true)
      expect(reviewed.ai_rating_unfavorable?("pattern")).to be(false)

      expect(reviewed.ai_rating_for("challenge")).to be_nil
      expect(reviewed.ai_rating_favorable?("challenge")).to be(false)
      expect(reviewed.ai_rating_unfavorable?("challenge")).to be(false)

      expect(unreviewed.ai_rating_for("code_review")).to be_nil
      expect(unreviewed.ai_rating_favorable?("code_review")).to be(false)
      expect(unreviewed.ai_rating_unfavorable?("code_review")).to be(false)
    end
  end

  describe "#self_rating_label" do
    it "matches the feedback form's copy and is nil when unrated" do
      right_level = user.daily_responses.create!(daily_exercise: exercise, date: Date.current, answers: {}, section_ratings: { "code_review" => "right_level" })
      unrated     = user.daily_responses.create!(daily_exercise: exercise, date: Date.current + 1, answers: {})

      expect(right_level.self_rating_label("code_review")).to eq("just right")
      expect(unrated.self_rating_label("code_review")).to be_nil
    end
  end

  describe "#improved_code_visible?" do
    def submit(concept:, date:)
      ex = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "concept" => concept } })
      user.daily_responses.create!(daily_exercise: ex, date: date, submitted_at: Time.current,
        answers: { "code_review" => "x" * 20 }, concept_tags: { "code_review" => concept })
    end

    it "hides improved_code on the first exposure and reveals it on the second" do
      first  = submit(concept: "n_plus_one", date: Date.current - 3)
      second = submit(concept: "n_plus_one", date: Date.current - 1)

      expect(first.improved_code_visible?("code_review")).to be(false)
      expect(second.improved_code_visible?("code_review")).to be(true)
    end

    it "is ungated for a blank or 'other' concept" do
      ex = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "concept" => "other" } })
      r = user.daily_responses.create!(daily_exercise: ex, date: Date.current, submitted_at: Time.current,
        answers: { "code_review" => "x" * 20 }, concept_tags: { "code_review" => "other" })
      expect(r.improved_code_visible?("code_review")).to be(true)
    end

    def submit_pattern(concept:, date:)
      ex = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "pattern" => { "concept" => concept } })
      user.daily_responses.create!(daily_exercise: ex, date: date, submitted_at: Time.current,
        answers: { "pattern" => "x" * 20 }, concept_tags: { "pattern" => concept })
    end

    it "applies the same first-exposure rule to the pattern section" do
      first  = submit_pattern(concept: "service_objects", date: Date.current - 3)
      second = submit_pattern(concept: "service_objects", date: Date.current - 1)

      expect(first.improved_code_visible?("pattern")).to be(false)
      expect(second.improved_code_visible?("pattern")).to be(true)
    end

    it "is always false for the architecture section, even on a repeat exposure" do
      first  = submit(concept: "service_boundaries", date: Date.current - 3)
      second = submit(concept: "service_boundaries", date: Date.current - 1)
      # improved_code_visible? is normally keyed by section+concept; pass
      # "architecture" directly to prove the exclusion is unconditional, not
      # incidentally true because these fixtures never tag an architecture
      # section.
      expect(first.improved_code_visible?("architecture")).to be(false)
      expect(second.improved_code_visible?("architecture")).to be(false)
    end

    describe "#improved_code_visible? for security_review" do
      it "is not excluded like architecture — it follows the normal concept-exposure gate" do
        exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
          problem_set: { "security_review" => { "concept" => "xss_prevention" } })
        response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
          answers: { "security_review" => "x" * 20 },
          concept_tags: { "security_review" => "xss_prevention" })

        # No prior exposure yet — gated closed, same rule code_review/pattern follow.
        expect(response.improved_code_visible?("security_review")).to be false
      end
    end
  end
end
