require "rails_helper"

RSpec.describe "Rating-gated answer submission", type: :system, with_csrf: true do
  # with_csrf: the submit script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).

  it "enables Submit only once every section is rated, then submits and shows the submitted state" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      visit_with_todays_set(user)
      # Regex: `.section-label` is uppercased by CSS and Playwright matches the rendered text.
      expect(page).to have_content(/Code Review/i, wait: 10)

      expect(page).to have_button("Submit answers", disabled: true)

      # Answer every section the page holds, since the count varies with the plan.
      fields = rating_row_fields
      fields.each { |field| fill_in_answer(field, "A substantive answer for #{field} that clears the length floor.") }

      fields[0..-2].each { |field| rate_section(field) }
      expect(page).to have_button("Submit answers", disabled: true)
      expect(page).to have_selector("#progress-label", exact_text: "✓ All answered")
      expect(page).to have_content("Rate each section you answered to finish up.")
      rate_section(fields.last)

      expect(page).to have_button("Submit answers", disabled: false)
      click_button "Submit answers"

      # review_request_spec covers the chained review; this only needs the gated click to have gone through.
      expect(page).to have_content("Review ready!", wait: 10)
      expect(user.daily_responses.sole).to be_submitted
    end
  end

  it "keeps draft ratings while clearing answers, but submits only ratings for answers kept" do
    user = create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)
      fill_in_answer("code_review", "A substantive answer that will stay.")
      rate_section("code_review")
      fill_in_answer("pattern", "A substantive answer that will be cleared.")
      rate_section("pattern", value: "too_hard")
      wait_for_saved_answer(user, "pattern", "A substantive answer that will be cleared.")
      fill_in_answer("pattern", "")
      wait_for_saved_answer(user, "pattern", "")
      visit root_path

      expect(page).to have_button("Submit answers", disabled: false)
      expect(page).to have_selector('button[data-rating-for="pattern"][data-rating="too_hard"].active')
      click_button "Submit answers"

      expect(page).to have_content("Review ready!", wait: 10)
      expect(user.daily_responses.reload.sole.section_ratings).to eq("code_review" => "right_level")
      expect(page).not_to have_selector(".history-pill", text: "Pattern: too hard")
    end
  end

  it "enables Submit once the answered sections are rated, and re-locks it when another section is answered" do
    user = create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS)
    weekday = a_weekday

    travel_to(weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      expect(page).to have_button("Submit answers", disabled: true)
      expect(page).to have_content("Answer at least one section to finish up.")

      fill_in_answer("code_review", "It re-runs the loyalty_tier query inside the loop — precompute it once outside the loop.")
      expect(page).to have_button("Submit answers", disabled: true)
      expect(page).to have_content("Rate each section you answered to finish up.")

      rate_section("code_review")
      expect(page).to have_button("Submit answers", disabled: false)

      fill_in_answer("pattern", "A service object because checkout has three unrelated responsibilities.")
      expect(page).to have_button("Submit answers", disabled: true)

      rate_section("pattern")
      expect(page).to have_button("Submit answers", disabled: false)
      click_button "Submit answers"

      expect(page).to have_content("Review ready!", wait: 10)
      response = user.daily_responses.sole
      expect(response).to be_submitted
      expect(response.section_ratings.keys).to contain_exactly("code_review", "pattern")
    end
  end

  [ :http, :network ].each do |failure|
    it "restores editing and autosaves the final edit after a #{failure} submission failure" do
      user = create_fake_provider_user

      travel_to(a_weekday) do
        visit_with_todays_set(user)
        expect(page).to have_content(/Code Review/i, wait: 10)
        original = "The earlier autosaved answer."
        final = "The final edit typed immediately before submission."
        fill_in_answer("code_review", original)
        rate_section("code_review")
        wait_for_saved_answer(user, "code_review", original)
        page.execute_script(<<~JS)
          const originalFetch = window.fetch;
          window.alert = () => {};
          window.submitRequests = 0;
          window.fetch = (url, options) => {
            if (options?.body && JSON.parse(options.body).response?.submit === "1") {
              window.submitRequests += 1;
              return new Promise((resolve, reject) => {
                window.finishSubmit = () => #{failure == :http ? 'resolve(new Response("", { status: 422 }))' : 'reject(new TypeError("Failed to fetch"))'};
              });
            }
            return originalFetch(url, options);
          };
          const textarea = document.querySelector('textarea[data-field="code_review"]');
          textarea.value = #{final.to_json};
          textarea.dispatchEvent(new Event("input", { bubbles: true }));
          document.querySelector("#gym-form").requestSubmit();
        JS

        page.execute_script('document.querySelector("textarea[data-field]").dispatchEvent(new Event("input"))')
        expect(page).to have_button("Submitting…", disabled: true)
        expect(page).to have_selector("#gym-form[inert]")
        page.execute_script('document.querySelector("#gym-form").dispatchEvent(new Event("submit", { cancelable: true }))')
        expect(page.evaluate_script("window.submitRequests")).to eq(1)
        expect(user.daily_responses.reload.sole.answers["code_review"]).to eq(original)

        page.execute_script("window.finishSubmit()")
        expect(page).to have_no_selector("#gym-form[inert]")
        expect(page).to have_button("Submit answers", disabled: false)
        wait_for_saved_answer(user, "code_review", final)
        expect(user.daily_responses.reload.sole).not_to be_submitted
        visit root_path
        expect(find('textarea[data-field="code_review"]').value).to eq(final)
        fill_in_answer("code_review", "")
        expect(page).to have_button("Submit answers", disabled: true)
      end
    end
  end

  it "reconciles a lost submission acknowledgement without restoring a pruned rating" do
    user = create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)
      fill_in_answer("code_review", "The answer that survives the lost submission acknowledgement.")
      rate_section("code_review")
      fill_in_answer("pattern", "The answer that will be cleared before submission.")
      rate_section("pattern", value: "too_hard")
      fill_in_answer("pattern", "")
      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.alert = () => {};
        window.fetch = async (url, options) => {
          const response = await originalFetch(url, options);
          if (options?.body && JSON.parse(options.body).response?.submit === "1") {
            throw new TypeError("Response lost after commit");
          }
          return response;
        };
      JS

      click_button "Submit answers"

      expect(page).to have_content("✓ Submitted", wait: 10)
      expect(page).to have_no_selector("#gym-form")
      expect(page).to have_selector("form.review-form")
      response = user.daily_responses.reload.sole
      expect(response).to have_attributes(submitted?: true, reviewed?: false)
      expect(response.answered_sections).to eq([ "code_review" ])
      expect(response.section_ratings).to eq("code_review" => "right_level")
    end
  end

  it "shows the committed submission with a review retry when the native review handoff throws" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)
      fill_in_answer("code_review", "The answer that will be submitted before navigation fails.")
      rate_section("code_review")
      page.execute_script(<<~JS)
        window.alert = message => sessionStorage.setItem("handoffFailure", message);
        HTMLFormElement.prototype.submit = function () {
          throw new DOMException("Automatic form navigation was refused", "SecurityError");
        };
      JS

      click_button "Submit answers"

      expect(page).to have_content("✓ Submitted", wait: 10)
      expect(page).to have_no_selector("#gym-form")
      expect(page).to have_selector("form.review-form")
      expect(page.evaluate_script('sessionStorage.getItem("handoffFailure")')).to include("Your answers were saved")
      expect(user.daily_responses.reload.sole).to have_attributes(submitted?: true, reviewed?: false)
      expect(user.daily_responses.sole.answers["code_review"]).to eq("The answer that will be submitted before navigation fails.")
      within("form.review-form") { find('button[type="submit"]').click }
      expect(page).to have_content("Review ready!", wait: 10)
    end
  end

  it "counts Unicode characters against the same answer floor as the server" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)
      rate_section("code_review")
      fill_in_answer("code_review", "🦆" * DailyResponse::ANSWER_MIN_LENGTH)
      expect(page).to have_button("Submit answers", disabled: true)
      expect(page).to have_content("Answer at least one section to finish up.")

      fill_in_answer("code_review", "🦆" * (DailyResponse::ANSWER_MIN_LENGTH + 1))
      expect(page).to have_button("Submit answers", disabled: false)
      click_button "Submit answers"
      expect(page).to have_content("Review ready!", wait: 10)
      expect(user.daily_responses.sole.answered_sections).to eq([ "code_review" ])
    end
  end

  it "ignores a late autosave acknowledgement during partial submit and still requests the review" do
    user = create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)
      hold_response_requests
      fill_in_answer("code_review", "The substantive answer to keep.")
      rate_section("code_review")
      fill_in_answer("pattern", "The substantive answer to clear.")
      rate_section("pattern", value: "too_hard")
      expect(page).to have_selector("#gym-form[data-autosave-queued]")

      fill_in_answer("pattern", "")
      click_button "Submit answers"
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

  # A design comparison's answer is written by its pick and reason controls, so answer through them.
  def fill_in_answer(field, text)
    comparison = first(%([data-comparison-answer="#{field}"]), minimum: 0)
    return find(%(textarea[data-field="#{field}"])).fill_in(with: text) unless comparison

    comparison.choose("Piece A")
    comparison.find("textarea[data-comparison-reason]").fill_in(with: text)
  end

  def wait_for_saved_answer(user, field, text)
    Timeout.timeout(10) do
      sleep 0.05 until user.daily_responses.reload.first&.answers&.fetch(field, nil) == text
    end
  end
end
