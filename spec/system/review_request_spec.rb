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

  it "shows the submitted state, not the answer form, when Back restores the page" do
    # Back can return to this URL two ways — a bfcache restore of the live page,
    # or a replay of the original response body from the HTTP cache — and each
    # is guarded separately (the dashboard's pageshow handler, and its no-store
    # header). This asserts the property both exist for, since which path a
    # browser takes varies by build. The bfcache driver forces the first one to
    # be reachable at all; see spec/support/system_test_helper.rb.
    driven_by(:capybara_playwright_bfcache)

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

      # history.back(), not Capybara's go_back: a bfcache restore fires no load
      # event, so go_back's wait-for-load only returns because the handler's
      # reload provides one — and the assertions below would never be reached
      # on the failing path.
      page.execute_script("history.back()")

      expect(page).to have_content("✓ Submitted", wait: 10)
      expect(page).to have_no_selector("textarea[data-field]")
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
