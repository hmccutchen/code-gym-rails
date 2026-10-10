require "rails_helper"

RSpec.describe "Requesting an AI review", type: :system, with_csrf: true do
  # with_csrf: submit and the chained review read the CSRF meta tag, which test config blanks (see csrf_helper.rb).

  it "reviews and shows the result on the dashboard from the submit click alone" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      rate_all_sections
      click_button "Submit answers"

      expect(page).to have_content("Review ready!", wait: 10)
      expect(page).to have_current_path(root_path)
      expect(page).to have_content("What you got right")
    end
  end

  it "shows the submitted state, not the answer form, when Back restores the page" do
    # Back can restore from bfcache or replay the cached response; this driver makes bfcache reachable at all.
    driven_by(:capybara_playwright_bfcache)

    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      rate_all_sections
      click_button "Submit answers"
      expect(page).to have_content("Review ready!", wait: 10)

      # Back changes no path now, so mark this document and wait for the mark to go before asserting.
      page.execute_script("window.__beforeBack = true")

      # history.back(), not go_back: a bfcache restore fires no load event, so go_back would hide the failing path.
      page.execute_script("history.back()")
      Timeout.timeout(10) { sleep 0.1 until page.evaluate_script("window.__beforeBack === undefined") }

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
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      rate_all_sections
      click_button "Submit answers"

      expect(page).to have_content("is limiting requests right now", wait: 10)
      expect(page).to have_content("✓ Submitted")
      expect(page).to have_selector("form.review-form button")
      expect(page).to have_button("Start over")
      expect(user.daily_responses.sole).to have_attributes(submitted?: true, reviewed?: false)
    end
  end
end
