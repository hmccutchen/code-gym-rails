require "rails_helper"

# with_csrf: submit and the chained review read the CSRF meta tag, which test config blanks (see csrf_helper.rb).
RSpec.describe "Requesting an AI review", type: :system, with_csrf: true do
  it "reviews and shows the result on the dashboard from the submit click alone" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      rate_all_sections
      click_button "Submit answers"

      expect(page).to have_content("Review ready!")
      expect(page).to have_current_path(root_path)
      expect(page).to have_content("What you got right")
    end
  end

  it "marks a blank section Skipped and grades a short answer like a longer one" do
    user = create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS)
    weekday = a_weekday

    travel_to(weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)

      fields = all("textarea[data-field]").map { |area| area["data-field"] }.uniq
      answered, _blank, short = fields.first(3)
      find(%(textarea[data-field="#{answered}"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )
      find(%(textarea[data-field="#{short}"])).fill_in(with: "N+1?")
      rate_section(answered)
      rate_section(short)
      click_button "Submit answers"

      expect(page).to have_content("Review ready!")
      expect(page).to have_selector(".review-rating", count: 2)
      expect(page).to have_selector(".review-ungraded", text: "Skipped", count: 2)
      expect(page).to have_no_selector(".review-ungraded", text: "Not graded")
      expect(page).to have_selector(".answer-display", text: "N+1?")
      expect(page).to have_no_text("Not counted as an answer.")
    end
  end

  it "shows the submitted state, not the answer form, when Back restores the page" do
    # Back can restore from bfcache or replay the cached response; this driver makes bfcache reachable at all.
    driven_by(:capybara_playwright_bfcache)

    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      rate_all_sections
      click_button "Submit answers"
      expect(page).to have_content("Review ready!")

      # Back changes no path now, so mark this document and wait for the mark to go before asserting.
      page.execute_script("window.__beforeBack = true")

      # history.back(), not go_back: a bfcache restore fires no load event, so go_back would hide the failing path.
      page.execute_script("history.back()")
      wait_for { page.evaluate_script("window.__beforeBack === undefined") }

      expect(page).to have_content("✓ Submitted")
      expect(page).to have_no_selector("textarea[data-field]")
    end
  end

  it "leaves a failed automatic review on the dashboard with the manual retry" do
    user = create_fake_provider_user
    weekday = a_weekday

    allow_any_instance_of(FakeService).to receive(:review_sections)
      .and_raise(ProviderError::RateLimitError, "slow down")

    travel_to(weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      rate_all_sections
      click_button "Submit answers"

      expect(page).to have_content("is limiting requests right now")
      expect(page).to have_content("✓ Submitted")
      expect(page).to have_selector("form.review-form button")
      expect(page).to have_button("Start over")
      expect(user.daily_responses.sole).to have_attributes(submitted?: true, reviewed?: false)
    end
  end
end
