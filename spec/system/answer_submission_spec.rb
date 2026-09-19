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

      # Answer every section the page actually holds (the count varies with
      # the day's plan), so "one left unrated" is the only thing blocking.
      fields = rating_row_fields
      fields.each { |field| fill_in_answer(field, "A substantive answer for #{field} that clears the length floor.") }

      # Rate every section but the last: with one answered section left
      # unrated, the gate must still be blocked.
      fields[0..-2].each { |field| rate_section(field) }
      expect(page).to have_button("Submit answers →", disabled: true)
      rate_section(fields.last)

      expect(page).to have_button("Submit answers →", disabled: false)
      click_button "Submit answers →"

      # A successful submit chains into the review, which lands back on the
      # dashboard's submitted state. review_request_spec covers the chain
      # itself; this one only needs the gated click to have gone through.
      expect(page).to have_content("Review ready!", wait: 10)
      expect(user.daily_responses.sole).to be_submitted
    end
  end

  it "enables Submit once the answered sections are rated, and re-locks it when another section is answered" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      expect(page).to have_button("Submit answers →", disabled: true)
      expect(page).to have_content("Answer at least one section to finish up.")

      fill_in_answer("code_review", "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop.")
      expect(page).to have_button("Submit answers →", disabled: true)
      expect(page).to have_content("Rate each section you answered to finish up.")

      rate_section("code_review")
      expect(page).to have_button("Submit answers →", disabled: false)

      fill_in_answer("pattern", "A service object because checkout has three unrelated responsibilities.")
      expect(page).to have_button("Submit answers →", disabled: true)

      rate_section("pattern")
      expect(page).to have_button("Submit answers →", disabled: false)
      click_button "Submit answers →"

      expect(page).to have_content("Review ready!", wait: 10)
      response = user.daily_responses.sole
      expect(response).to be_submitted
      expect(response.section_ratings.keys).to contain_exactly("code_review", "pattern")
    end
  end

  def fill_in_answer(field, text)
    find(%(textarea[data-field="#{field}"])).fill_in(with: text)
  end
end
