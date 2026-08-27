require "rails_helper"

RSpec.describe "Requesting an AI review", type: :system, with_csrf: true do
  # allow_forgery_protection off (config/environments/test.rb) also blanks
  # csrf_meta_tags — the dashboard's inline submit script reads that meta tag
  # and throws on a real browser exercising the real fetch/CSRF path. This
  # spec submits answers through that same flow, and the review it chains into
  # carries its own token from the same tag, so it needs :with_csrf
  # (spec/support/csrf_helper.rb) turned on.

  it "reviews and lands on history from the submit click alone" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      rate_all_sections
      click_button "Submit answers →"

      expect(page).to have_current_path(%r{/history}, wait: 10)
      expect(page).to have_content("What you got right")
    end
  end

  it "leaves a failed automatic review on the dashboard with the manual retry" do
    user = create_fake_provider_user
    weekday = a_weekday

    allow_any_instance_of(FakeService).to receive(:review_sections)
      .and_raise(AiService::RateLimitError, "slow down")

    travel_to(weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      rate_all_sections
      click_button "Submit answers →"

      expect(page).to have_content("rate-limiting", wait: 10)
      expect(page).to have_content("✓ Submitted")
      expect(page).to have_selector("form.review-form button")
      expect(page).to have_button("Start over")
      expect(user.daily_responses.sole).to have_attributes(submitted?: true, reviewed?: false)
    end
  end
end
