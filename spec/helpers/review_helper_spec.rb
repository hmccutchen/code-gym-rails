require "rails_helper"

RSpec.describe ReviewHelper, type: :helper do
  let(:user) { User.create!(email: "review-helper@example.com", name: "R") }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "q" }, "pattern" => { "question" => "p" } })
  end

  describe "#review_badge" do
    {
      "the rating on an answered section"                 => [ "a" * 20, { "rating" => "strong" }, [ "strong", true ] ],
      "Skipped on an unanswered section with a rating"    => [ "", { "rating" => "strong" }, [ "Skipped", false ] ],
      "Skipped on an unanswered section without a rating" => [ "", {}, [ "Skipped", false ] ],
      "nothing on an answered section without a rating"   => [ "a" * 20, {}, nil ]
    }.each do |label, (written, review, expected)|
      it "gives #{label}" do
        response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
                                                answers: { "code_review" => written }, ai_review: { "code_review" => review })
        badge = helper.review_badge(response, "code_review")

        expect(badge && [ badge.text, badge.graded? ]).to eq(expected)
      end
    end
  end

  describe "#review_short_version" do
    let(:guide) do
      { tagline: "t", explanation: "e", code_example: "c", senior_lens: "s",
        guide_plain_language: "p", guide_worked_example: "w", guide_pitfalls: "f" }
    end

    def reviewed(rating:, gaps:)
      user.daily_responses.create!(daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                                   answers: { "code_review" => "a" * 20 }, concept_tags: { "code_review" => "n_plus_one" },
                                   ai_review: { "code_review" => { "rating" => rating, "missed" => [ "m" ], "essential_gaps" => gaps } })
    end

    it "gives the reference row, its bucket and whether pitfalls show, for a section that offers it" do
      reference = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)

      offer = helper.review_short_version(reviewed(rating: "developing", gaps: [ 0 ]), "code_review")

      expect(offer).to have_attributes(reference: reference, bucket: "ruby_rails", show_pitfalls: true)
    end

    it "gives nothing when the concept has no reference row" do
      expect(helper.review_short_version(reviewed(rating: "developing", gaps: [ 0 ]), "code_review")).to be_nil
    end

    it "gives nothing for a section that doesn't offer it" do
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", **guide)

      expect(helper.review_short_version(reviewed(rating: "developing", gaps: [ 0 ]), "pattern")).to be_nil
    end
  end

  describe "#review_field_label" do
    let(:response) { DailyResponse.new(daily_exercise: exercise, answers: { "code_review" => "a" * 20, "pattern" => "" }) }

    it "uses the walkthrough heading for the missed list on an unanswered section" do
      expect(helper.review_field_label(response, "pattern", "missed")).to eq("What a good answer covers")
    end

    it "uses the graded heading for the missed list on an answered section" do
      expect(helper.review_field_label(response, "code_review", "missed")).to eq("What you missed")
    end

    it "leaves a field with no walkthrough heading unchanged on an unanswered section" do
      expect(helper.review_field_label(response, "pattern", "next_step")).to eq("Next step")
    end
  end
end
