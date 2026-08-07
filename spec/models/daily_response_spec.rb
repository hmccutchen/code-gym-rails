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

    context "with a scaffolded section" do
      let(:scaffold) { [ "Which cache, and why:", "How you'd invalidate it:" ] }

      let(:scaffolded_exercise) do
        user.daily_exercises.create!(
          date: Date.current, generated_at: Time.current,
          problem_set: { "architecture" => { "question" => "q", "answer_scaffold" => scaffold } }
        )
      end

      def response_with(answer)
        DailyResponse.new(user: user, daily_exercise: scaffolded_exercise, date: Date.current,
                          answers: { "architecture" => answer })
      end

      def template
        ExerciseSection::Architecture.answer_template(scaffolded_exercise.problem_set["architecture"])
      end

      it "does not count a section holding nothing but its scaffold" do
        expect(response_with(template).answered_sections).to be_empty
      end

      # The labels alone are well past the threshold, so without stripping them
      # a two-word answer under a label would count as answered.
      it "measures only what the user typed under the labels" do
        expect(response_with(template + "Redis").answered_sections).to be_empty
        expect(response_with(template + "Redis, because reads dominate").answered_sections)
          .to eq([ "architecture" ])
      end

      # A row generated before answer_scaffold existed still has its kind's
      # default labels stripped, so it behaves exactly as it does today.
      it "falls back to the kind's default labels when the problem carries no scaffold" do
        legacy = user.daily_exercises.create!(
          date: Date.current - 1, generated_at: Time.current,
          problem_set: { "architecture" => { "question" => "q" } }
        )
        pristine = ExerciseSection::Architecture::DEFAULT_SCAFFOLD.join("\n\n\n")
        legacy_response = DailyResponse.new(user: user, daily_exercise: legacy, date: legacy.date,
                                            answers: { "architecture" => pristine })

        expect(legacy_response.answered_sections).to be_empty
      end
    end

    it "leaves untemplated kinds on the plain length rule" do
      daily_response = user.daily_responses.create!(
        daily_exercise: exercise,
        date: Date.current,
        answers: { "code_review" => "Which option, and why:" }
      )

      expect(daily_response.answered_sections).to eq([ "code_review" ])
    end
  end

  describe ".normalize_answers" do
    let(:scaffold) { [ "Which cache, and why:", "How you'd invalidate it:" ] }

    let(:scaffolded_exercise) do
      user.daily_exercises.create!(
        date: Date.current, generated_at: Time.current,
        problem_set: { "architecture" => { "question" => "q", "answer_scaffold" => scaffold },
                       "code_review"  => { "question" => "q", "snippet" => "s" } }
      )
    end

    def template
      ExerciseSection::Architecture.answer_template(scaffolded_exercise.problem_set["architecture"])
    end

    it "blanks a section holding nothing but its scaffold" do
      expect(DailyResponse.normalize_answers({ "architecture" => template }, scaffolded_exercise))
        .to eq("architecture" => "")
    end

    it "preserves the labels verbatim once the user has typed under them" do
      filled = template + "Redis"
      expect(DailyResponse.normalize_answers({ "architecture" => filled }, scaffolded_exercise))
        .to eq("architecture" => filled)
    end

    it "leaves untemplated sections untouched" do
      expect(DailyResponse.normalize_answers({ "code_review" => "  the N+1  " }, scaffolded_exercise))
        .to eq("code_review" => "  the N+1  ")
    end

    it "blanks a whitespace-only answer for any kind" do
      expect(DailyResponse.normalize_answers({ "code_review" => "   " }, scaffolded_exercise))
        .to eq("code_review" => "")
    end

    it "tolerates a nil exercise by falling back to the kind's default labels" do
      pristine = ExerciseSection::Architecture::DEFAULT_SCAFFOLD.join("\n\n\n")
      expect(DailyResponse.normalize_answers({ "architecture" => pristine }, nil))
        .to eq("architecture" => "")
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

  describe "#history_page" do
    def submitted_response_on(owner, date)
      exercise = owner.daily_exercises.create!(
        date: date,
        generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
      owner.daily_responses.create!(
        daily_exercise: exercise,
        date: date,
        answers: { "code_review" => "An answer with real substance" },
        submitted_at: Time.current
      )
    end

    it "puts the ten newest sessions on page 1 and the eleventh on page 2" do
      responses = (0..10).map { |i| submitted_response_on(user, i.days.ago.to_date) }

      expect(responses[0].history_page).to eq(1)
      expect(responses[9].history_page).to eq(1)
      expect(responses[10].history_page).to eq(2)
    end

    it "ignores unsubmitted drafts, which never appear in history at all" do
      target = submitted_response_on(user, 20.days.ago.to_date)
      (0..9).each do |i|
        date = i.days.ago.to_date
        draft_exercise = user.daily_exercises.create!(
          date: date,
          generated_at: Time.current,
          problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
        )
        user.daily_responses.create!(daily_exercise: draft_exercise, date: date, answers: {})
      end

      expect(target.history_page).to eq(1)
    end

    it "ignores another user's sessions" do
      other = User.create!(email: "other@example.com", name: "Other")
      (0..9).each { |i| submitted_response_on(other, i.days.ago.to_date) }
      target = submitted_response_on(user, 20.days.ago.to_date)

      expect(target.history_page).to eq(1)
    end
  end

  describe "#fully_reviewed?" do
    def exercise_with_three_sections
      user = User.create!(email: "fr_test@example.com", name: "FR")
      DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current,
        language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s" },
          "pattern"     => { "title" => "t", "question" => "q" },
          "challenge"   => { "question" => "q" }
        }
      )
    end

    it "is false when ai_review is blank" do
      exercise = exercise_with_three_sections
      response = DailyResponse.create!(user: exercise.user, daily_exercise: exercise, date: Date.current, answers: {})
      expect(response).not_to be_fully_reviewed
    end

    it "is false when only some sections are present" do
      exercise = exercise_with_three_sections
      response = DailyResponse.create!(
        user: exercise.user, daily_exercise: exercise, date: Date.current, answers: {},
        ai_review: { "code_review" => { "rating" => "solid" } }
      )
      expect(response).not_to be_fully_reviewed
    end

    it "is true when every exercise section is present in ai_review" do
      exercise = exercise_with_three_sections
      response = DailyResponse.create!(
        user: exercise.user, daily_exercise: exercise, date: Date.current, answers: {},
        ai_review: {
          "code_review" => { "rating" => "solid" },
          "pattern"     => { "rating" => "solid" },
          "challenge"   => { "rating" => "solid" }
        }
      )
      expect(response).to be_fully_reviewed
    end
  end

  describe "#section_reviewed?" do
    it "is true only for a section with a Hash entry in ai_review" do
      user = User.create!(email: "sr_test@example.com", name: "SR")
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } }
      )
      response = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current, answers: {},
        ai_review: { "code_review" => { "rating" => "solid" } }
      )
      expect(response.section_reviewed?("code_review")).to be(true)
      expect(response.section_reviewed?("pattern")).to be(false)
    end
  end
end
