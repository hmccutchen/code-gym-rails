require "rails_helper"

RSpec.describe ReviewHelper, type: :helper do
  let(:user) { User.create!(email: "review-helper@example.com", name: "R") }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "q" }, "pattern" => { "question" => "p" } })
  end

  describe "#review_provider_label" do
    let(:openai_user) { User.create!(email: "label@example.com", name: "L", provider: "openai", api_keys: { "openai" => "sk-proj-x" }) }

    it "names the provider that wrote the review" do
      expect(helper.review_provider_label(DailyResponse.new(user: openai_user, review_provider: "anthropic"))).to eq("Claude")
    end

    it "names the user's provider for a review written before it was recorded" do
      expect(helper.review_provider_label(DailyResponse.new(user: openai_user, review_provider: nil))).to eq("GPT")
    end
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
