require "rails_helper"

RSpec.describe "A bug_hunt section and concept mastery" do
  let(:user) { User.create!(email: "hunt-mastery@example.com", name: "Hunt") }

  def hunt(concept) = { "concept" => concept, "purpose" => "Return whether the account may sign in.", "snippet" => "x", "pitched_at" => "junior" }

  def plain(concept) = { "concept" => concept, "pitched_at" => "junior" }

  def reviewed_day(sections, date: Date.current, self_rating: "right_level", ai_rating: "solid")
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails", problem_set: sections)
    user.daily_responses.create!(daily_exercise: exercise, date: date, submitted_at: Time.current,
                                 answers: sections.transform_values { "x" * 20 },
                                 section_ratings: sections.transform_values { self_rating },
                                 concept_tags: sections.transform_values { |section| section["concept"] },
                                 ai_review: sections.transform_values { { "rating" => ai_rating, "correct" => "c" } })
  end

  def record!(response) = ConceptMastery.record_review!(response, sections: response.concept_tags.keys, apply_session_countdown: true)

  describe "ConceptMastery.record_review!" do
    it "leaves a concept carried only by a bug_hunt section unevaluated" do
      record!(reviewed_day({ "code_review" => hunt("memoization") }))

      expect(user.concept_masteries.find_by(concept: "memoization")).to be_nil
    end

    it "leaves an existing tier, streak, drill and schedule alone" do
      held = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard, streak: 1,
                                            mastered_at: 1.month.ago, retention_interval_days: 7,
                                            next_retention_check_on: Date.current + 3, drilled_at: Time.current)

      record!(reviewed_day({ "code_review" => hunt("memoization") }, self_rating: "too_hard", ai_rating: "beginner"))

      expect(held.reload).to have_attributes(tier: "standard", streak: 1, retention_interval_days: 7,
                                             next_retention_check_on: Date.current + 3)
      expect(held.drilled_at).to be_present
    end

    context "with a retention check due on the concept" do
      let!(:due) do
        user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard, streak: 1,
                                       mastered_at: 1.month.ago, retention_interval_days: 7,
                                       next_retention_check_on: Date.current - 1)
      end

      def skipped_day(sections, answered:)
        reviewed_day(sections).tap { |response| response.update!(answers: response.answers.slice(*answered)) }
      end

      it "leaves the check due when the skipped section is a bug_hunt" do
        record!(skipped_day({ "code_review" => hunt("memoization"), "design_comparison" => plain("caching") },
                            answered: %w[design_comparison]))

        expect(due.reload.next_retention_check_on).to eq(Date.current - 1)
      end

      it "defers the check for a skipped section when a bug_hunt is the only answered section carrying the concept" do
        record!(skipped_day({ "code_review" => hunt("memoization"), "pattern" => plain("memoization") },
                            answered: %w[code_review]))

        expect(due.reload.next_retention_check_on).to eq(Date.current + 7)
      end
    end

    it "evaluates a concept the day carries elsewhere from that other section alone" do
      record!(reviewed_day({ "code_review" => hunt("memoization"), "pattern" => plain("memoization") }))

      expect(user.concept_masteries.find_by(concept: "memoization")).to have_attributes(last_rating: "solid", tier: "standard")
    end
  end

  describe "User#concepts_needing_reinforcement" do
    it "lets an older real-code rating decide, rather than a newer puzzle" do
      reviewed_day({ "code_review" => plain("memoization") }, date: Date.current - 2, self_rating: "too_hard", ai_rating: "developing")
      reviewed_day({ "code_review" => hunt("memoization") }, date: Date.current - 1)

      expect(user.concepts_needing_reinforcement.map { |entry| entry[:concept] }).to include("memoization")
    end

    it "never puts a concept on the list from a puzzle alone" do
      reviewed_day({ "code_review" => hunt("memoization") }, self_rating: "too_hard", ai_rating: "beginner")

      expect(user.concepts_needing_reinforcement).to be_empty
    end
  end

  describe "RungLedger" do
    it "holds no rung from a bug_hunt section" do
      ledger = RungLedger.new([ reviewed_day({ "code_review" => hunt("memoization") }) ])

      expect(ledger.held("memoization", "ruby_rails")).to be_nil
      expect(ledger.developing_toward("memoization", "ruby_rails")).to be_nil
    end
  end

  describe "what still counts" do
    it "counts the section as an exposure" do
      reviewed_day({ "code_review" => hunt("memoization") })

      expect(ConceptExposureIndex.for(user).count("memoization", "ruby_rails", on_or_before: Date.current)).to eq(1)
    end

    it "counts the section as code_review evidence for the competency gate and level suggestions" do
      response = reviewed_day({ "code_review" => hunt("memoization") })

      expect(ReviewedSectionResults.for(response).map(&:kind)).to eq(%w[code_review])
    end
  end
end
