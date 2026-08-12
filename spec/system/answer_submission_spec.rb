require "rails_helper"

RSpec.describe "Rating-gated answer submission", type: :system, with_csrf: true do
  # allow_forgery_protection off (config/environments/test.rb) also blanks
  # csrf_meta_tags — the dashboard's inline submit script reads that meta tag
  # and throws on a real browser exercising the real fetch/CSRF path, so this
  # spec needs :with_csrf (spec/support/csrf_helper.rb) turned on.

  it "enables Submit only once every section is rated, then submits and shows the submitted state" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      perform_enqueued_jobs { visit_as(user) }
      # Regex, not a literal string: this label renders inside
      # `.section-label` (CSS `text-transform: uppercase`), and the
      # Playwright driver matches on rendered text — see
      # dashboard_generation_spec.rb for the full explanation.
      expect(page).to have_content(/Code Review/i, wait: 10)

      expect(page).to have_button("Submit answers →", disabled: true)

      fill_in_answer("code_review", "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop.")
      fill_in_answer("pattern", "A service object because checkout has three unrelated responsibilities.")
      fill_in_answer("architecture", "Move the email to a background job; checkout latency matters more than instant confirmation.")

      # Rate every section but the last: whatever sections the page actually
      # holds (rate_all_sections reads that from the DOM, see system_test_helper),
      # the gate must still be blocked with one left unrated.
      fields = rating_row_fields
      fields[0..-2].each { |field| rate_section(field) }
      expect(page).to have_button("Submit answers →", disabled: true)
      rate_section(fields.last)

      expect(page).to have_button("Submit answers →", disabled: false)
      click_button "Submit answers →"

      expect(page).to have_content("✓ Submitted", wait: 10)
    end
  end

  def fill_in_answer(field, text)
    find(%(textarea[data-field="#{field}"])).fill_in(with: text)
  end
end
