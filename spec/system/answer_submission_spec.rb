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
      expect(page).to have_selector("#progress-label", exact_text: "✓ All answered")
      expect(page).to have_content("Rate each section you answered to finish up.")
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

  it "keeps draft ratings while clearing answers, but submits only ratings for answers kept" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)
      fill_in_answer("code_review", "A substantive answer that will stay.")
      rate_section("code_review")
      fill_in_answer("pattern", "A substantive answer that will be cleared.")
      rate_section("pattern", value: "too_hard")
      wait_for_saved_answer(user, "pattern", "A substantive answer that will be cleared.")
      fill_in_answer("pattern", "")
      wait_for_saved_answer(user, "pattern", "")
      visit root_path

      expect(page).to have_button("Submit answers →", disabled: false)
      expect(page).to have_selector('button[data-rating-for="pattern"][data-rating="too_hard"].active')
      click_button "Submit answers →"

      expect(page).to have_content("Review ready!", wait: 10)
      expect(user.daily_responses.reload.sole.section_ratings).to eq("code_review" => "right_level")
      expect(page).not_to have_selector(".history-pill", text: "Pattern: too hard")
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

  it "freezes the submitted snapshot until a failed request returns, then restores editing" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)
      fill_in_answer("code_review", "A substantive answer for the submitted snapshot.")
      rate_section("code_review")
      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.alert = () => {};
        window.submitRequests = 0;
        window.fetch = (url, options) => {
          if (options?.body && JSON.parse(options.body).response?.submit === "1") {
            window.submitRequests += 1;
            return new Promise((resolve) => { window.finishSubmit = () => resolve({ ok: false }); });
          }
          return originalFetch(url, options);
        };
      JS

      click_button "Submit answers →"
      page.execute_script('document.querySelector("textarea[data-field]").dispatchEvent(new Event("input"))')
      expect(page).to have_button("Submitting…", disabled: true)
      expect(page).to have_selector("#gym-form[inert]")
      page.execute_script('document.querySelector("#gym-form").dispatchEvent(new Event("submit", { cancelable: true }))')
      expect(page.evaluate_script("window.submitRequests")).to eq(1)

      page.execute_script("window.finishSubmit()")
      expect(page).to have_no_selector("#gym-form[inert]")
      expect(page).to have_button("Submit answers →", disabled: false)
      fill_in_answer("code_review", "")
      expect(page).to have_button("Submit answers →", disabled: true)
    end
  end

  it "counts Unicode characters against the same answer floor as the server" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)
      rate_section("code_review")
      fill_in_answer("code_review", "🦆" * DailyResponse::ANSWER_MIN_LENGTH)
      expect(page).to have_button("Submit answers →", disabled: true)
      expect(page).to have_content("Answer at least one section to finish up.")

      fill_in_answer("code_review", "🦆" * (DailyResponse::ANSWER_MIN_LENGTH + 1))
      expect(page).to have_button("Submit answers →", disabled: false)
      click_button "Submit answers →"
      expect(page).to have_content("Review ready!", wait: 10)
      expect(user.daily_responses.sole.answered_sections).to eq([ "code_review" ])
    end
  end

  it "ignores a late autosave acknowledgement during partial submit and still requests the review" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)
      hold_response_requests
      fill_in_answer("code_review", "The substantive answer to keep.")
      rate_section("code_review")
      fill_in_answer("pattern", "The substantive answer to clear.")
      rate_section("pattern", value: "too_hard")
      expect(page).to have_selector("#gym-form[data-autosave-queued]")

      fill_in_answer("pattern", "")
      click_button "Submit answers →"
      expect(page).to have_selector("#gym-form[data-submit-stored]")
      page.execute_script("window.releaseAutosave()")
      expect(page).to have_selector('#gym-form[data-autosave-returned="true"]')
      page.driver.with_playwright_page { |browser| browser.wait_for_load_state(state: "networkidle") }
      expect(page).to have_button("Submitting…", disabled: true)
      expect(page).to have_selector("#gym-form[inert]")

      page.execute_script("window.releaseSubmission()")
      expect(page).to have_content("Review ready!", wait: 10)
      saved = user.daily_responses.reload.sole
      expect(saved.answers["pattern"]).to eq("")
      expect(saved.section_ratings).to eq("code_review" => "right_level")
    end
  end

  def hold_response_requests
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      const originalSave = window.CodeGymSaveStatus.save;
      window.CodeGymSaveStatus.save = (...args) => originalSave(...args).then(result => {
        document.querySelector("#gym-form").dataset.autosaveReturned = String(result.data?.submitted);
        return result;
      });
      window.fetch = (url, options) => {
        if (new URL(url, location.href).pathname !== "/responses") return originalFetch(url, options);
        if (JSON.parse(options.body).response.submit === "1") {
          return originalFetch(url, options).then(response => {
            document.querySelector("#gym-form").dataset.submitStored = "true";
            return new Promise(resolve => { window.releaseSubmission = () => resolve(response); });
          });
        }
        document.querySelector("#gym-form").dataset.autosaveQueued = "true";
        return new Promise(resolve => {
          window.releaseAutosave = () => originalFetch(url, options).then(resolve);
        });
      };
    JS
  end

  def fill_in_answer(field, text)
    find(%(textarea[data-field="#{field}"])).fill_in(with: text)
  end

  def wait_for_saved_answer(user, field, text)
    Timeout.timeout(10) do
      sleep 0.05 until user.daily_responses.reload.first&.answers&.fetch(field, nil) == text
    end
  end
end
