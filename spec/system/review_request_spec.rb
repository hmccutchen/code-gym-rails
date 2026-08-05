require "rails_helper"

RSpec.describe "Requesting an AI review", type: :system, with_csrf: true do
  # allow_forgery_protection off (config/environments/test.rb) also blanks
  # csrf_meta_tags — the dashboard's inline submit script reads that meta tag
  # and throws on a real browser exercising the real fetch/CSRF path. This
  # spec's setup submits answers via that same flow before requesting a
  # review, so it needs :with_csrf (spec/support/csrf_helper.rb) turned on.

  it "requests a review and lands on history with the review visible" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop."
      )

      %w[code_review pattern architecture].each do |field|
        find(%(button[data-rating-for="#{field}"][data-rating="right_level"])).click
      end
      click_button "Submit answers →"
      expect(page).to have_content("✓ Submitted")

      review_button = find("form.review-form button", match: :first)
      review_button.click

      expect(page).to have_current_path(%r{/history}, wait: 10)
      expect(page).to have_content("What you got right")
    end
  end
end
