require "rails_helper"

RSpec.describe "Requesting an AI review", type: :system do
  # allow_forgery_protection is off app-wide in test (config/environments/test.rb),
  # which also blanks csrf_meta_tags — the dashboard's inline submit script reads
  # that meta tag and throws on a real browser exercising the real fetch/CSRF path.
  # This spec's setup submits answers via that same flow before requesting a
  # review, so it needs the same toggle Task 7's spec uses (and
  # spec/requests/sessions_spec.rb uses for its own CSRF-dependent examples).
  around do |example|
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  it "runs the loading-state script and lands on history with the review visible" do
    user = create_fake_provider_user
    monday = Date.current.beginning_of_week(:monday)

    travel_to(monday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

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
