require "rails_helper"

RSpec.describe "A review still running when the dashboard loads", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  def submitted_response(owner: user, reviewing_since: nil, ai_review: nil, review_errors: {})
    exercise = DailyExercise.create!(
      user: owner, date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s" },
                     "pattern" => { "title" => "t", "question" => "q" } }
    )
    DailyResponse.create!(
      user: owner, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
      reviewing_since: reviewing_since, ai_review: ai_review, review_errors: review_errors
    )
  end

  def stale_claim = (DailyResponse::REVIEW_CLAIM_STALE_AFTER + 1.minute).ago

  def page_html
    get root_path
    Nokogiri::HTML(response.body)
  end

  def in_progress_hint = I18n.t("review.in_progress.hint")

  describe "GET /responses/:id/review_status" do
    it "says pending while the review claim is held" do
      daily_response = submitted_response(reviewing_since: 1.minute.ago)

      get review_status_response_path(daily_response)

      expect(response.parsed_body).to eq("status" => "pending")
    end

    it "says ready once the claim is released" do
      daily_response = submitted_response(ai_review: { "code_review" => { "rating" => "solid" } })

      get review_status_response_path(daily_response)

      expect(response.parsed_body).to eq("status" => "ready")
    end

    it "says ready once a claim left by a killed request has gone stale" do
      daily_response = submitted_response(reviewing_since: stale_claim)

      get review_status_response_path(daily_response)

      expect(response.parsed_body).to eq("status" => "ready")
    end

    it "does not answer for another user's response" do
      other = create_user_with_key(email: "other@example.com", name: "Other")

      get review_status_response_path(submitted_response(owner: other))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the submitted dashboard" do
    it "shows the review as running, polling its status, in place of the review button" do
      daily_response = submitted_response(reviewing_since: 1.minute.ago)

      page = page_html

      expect(page.css("form.review-form")).to be_empty
      expect(page.at_css("button.btn-loading[disabled]").text).to eq(I18n.t("review.generating_label"))
      expect(page.at_css(".review-in-progress").text).to eq(in_progress_hint)
      expect(page.at_css("[data-controller='generating']")["data-generating-url-value"])
        .to eq(review_status_response_path(daily_response))
    end

    it "keeps the part already reviewed and drops the old failure while a retry runs" do
      submitted_response(
        reviewing_since: 1.minute.ago,
        ai_review: { "code_review" => { "rating" => "solid", "correct" => "Right" } },
        review_errors: { "pattern" => { "kind" => "short_rate_limit", "provider" => "claude", "at" => 1.hour.ago.iso8601 } }
      )

      page = page_html

      expect(page.at_css("#ai-review")).to be_present
      expect(page.css("form.review-form")).to be_empty
      expect(page.css(".review-failure")).to be_empty
      expect(page.at_css(".review-in-progress")).to be_present
    end

    it "offers the review button again once the claim has gone stale" do
      submitted_response(reviewing_since: stale_claim)

      page = page_html

      expect(page.at_css("form.review-form button").text).to eq("Get Claude review")
      expect(page.css(".review-in-progress")).to be_empty
    end

    it "shows the review button, not the running state, for a day never reviewed" do
      submitted_response

      page = page_html

      expect(page.at_css("form.review-form")).to be_present
      expect(page.css(".review-in-progress")).to be_empty
    end
  end
end
