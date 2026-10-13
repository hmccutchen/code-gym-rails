require "rails_helper"

RSpec.describe GenerationFailureHelper, type: :helper do
  describe "#review_failure_sentence" do
    let(:user) { create_user_with_key }
    let(:failed_at) { 1.minute.ago.change(usec: 0) }

    def response_with(review_error)
      exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                       problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
      user.daily_responses.create!(daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                                   answers: { "code_review" => "a" * 20 },
                                   review_errors: { "code_review" => review_error.merge("at" => failed_at.iso8601) })
    end

    def sentence_for(kind)
      ProviderFailureText.new(kind, provider: user.provider, surface: :review, failed_at: failed_at,
                              zone: user.effective_time_zone, variant: ProviderFailureText.variant_for(user)).full
    end

    it "words a stored failure by its kind" do
      expect(helper.review_failure_sentence(response_with("kind" => "short_rate_limit"))).to eq(sentence_for("short_rate_limit"))
    end

    it "words a row with no kind as other, whatever older field it carries" do
      sentence = helper.review_failure_sentence(response_with("code" => "rate_limit"))

      expect(sentence).to eq(sentence_for("other"))
      expect(sentence).not_to eq(sentence_for("short_rate_limit"))
    end
  end
end
