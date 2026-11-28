require "rails_helper"

RSpec.describe "Readiness after appending an exercise", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  it "preserves another tab's saved answer and rating when an untouched tab learns about an append" do
    exercise = create_existing_set(user, keys: %w[code_review])
    response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "The original saved answer." },
      section_ratings: { "code_review" => "right_level" })
    visit_as(user)
    wait_for_js
    wait_for_answers_settled
    expect(find('textarea[data-field="code_review"]').value).to eq("The original saved answer.")

    response.update!(answers: { "code_review" => "The other tab's newer explanation." },
      section_ratings: { "code_review" => "too_easy" })
    exercise.update!(problem_set: exercise.problem_set.merge("pattern" => FakeService::EXERCISE_PROBLEM_SET.fetch("pattern")),
      section_order: %w[code_review pattern])
    page.execute_script('window.dispatchEvent(new Event("focus"))')

    expect(page).to have_css('[data-section-fold="pattern"]')
    wait_for_js_condition(<<~JS.squish)
      window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller~="answer-form"]'), "answer-form").saveTimer === null
    JS
    wait_for_answers_settled

    aggregate_failures do
      expect(response.reload.answers.fetch("code_review")).to eq("The other tab's newer explanation.")
      expect(response.section_ratings.fetch("code_review")).to eq("too_easy")
    end
  end

  [ :blank, :unrated ].each do |added|
    it "#{added == :blank ? 'keeps a valid session ready' : 'blocks submission'} after a #{added} new card without saving old fields" do
      exercise = create_existing_set(user, keys: %w[code_review])
      response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "Move the query outside the loop." },
        section_ratings: { "code_review" => "right_level" })
      visit_as(user)
      wait_for_js
      expect_ready_to_submit
      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.answerPosts = 0;
        window.fetch = (url, options) => {
          if (String(url).endsWith('/responses') && options?.method === 'POST') window.answerPosts++;
          return originalFetch(url, options);
        };
      JS
      exercise.update!(problem_set: exercise.problem_set.merge("design_comparison" => FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison")),
        section_order: %w[code_review design_comparison])
      response.update!(answers: response.answers.merge("design_comparison" => "pick:a\nA bounded operation.")) if added == :unrated
      page.execute_script('window.dispatchEvent(new Event("focus"))')

      expect(page).to have_css('[data-section-fold="design_comparison"]')
      expect(page).to have_button("Submit answers", disabled: added == :unrated)
      expect(page.evaluate_script("window.answerPosts")).to eq(0)
      expect(response.reload.answers.fetch("code_review")).to eq("Move the query outside the loop.")
    end
  end

  it "does not enable an old blank form because another tab answered an existing section before Add" do
    exercise = create_existing_set(user, keys: %w[code_review])
    visit_as(user)
    wait_for_js
    expect(page).to have_button("Submit answers", disabled: true)
    user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "An answer saved from the other tab." },
      section_ratings: { "code_review" => "right_level" })
    exercise.update!(problem_set: exercise.problem_set.merge("pattern" => FakeService::EXERCISE_PROBLEM_SET.fetch("pattern")),
      section_order: %w[code_review pattern])
    page.execute_script('window.dispatchEvent(new Event("focus"))')

    expect(page).to have_css('[data-section-fold="pattern"]')
    expect(page).to have_button("Submit answers", disabled: true)
    expect(find('textarea[data-field="code_review"]').value).to be_empty
  end

  {
    unchanged: "confirms a saved edit when its newer manifest reply arrives before the appended card",
    rating_clear: "does not confirm a later rating clear with the retained manifest acknowledgment",
    advanced: "does not confirm a retained acknowledgment after the manifest advances again",
    wrong_scope: "rejects another scope's structure without consuming the valid retained acknowledgment",
    added_unrated: "keeps a later saved unrated addition blocked when applying the retained acknowledgment"
  }.each do |intervening, description|
    it description do
      exercise = create_existing_set(user, keys: %w[code_review])
      response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "The original saved answer." },
        section_ratings: { "code_review" => "right_level" })
      visit_as(user)
      wait_for_js
      expect_ready_to_submit
      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.answerPosts = 0;
        window.heldAdditionReads = [];
        window.holdAdditionReads = true;
        window.fetch = (url, options) => {
          const path = new URL(url, location.href).pathname;
          if (path === '/exercise_additions' && options?.method !== 'POST' && window.holdAdditionReads) {
            window.reconcileOtherScope = async () => {
              const data = await (await originalFetch(url, options)).json();
              data.draft_scope += '-another-set';
              const form = document.querySelector('[data-controller~="answer-form"]');
              return window.Stimulus.getControllerForElementAndIdentifier(form, 'answer-form').reconcileStructure(data);
            };
            return new Promise(resolve => window.heldAdditionReads.push(() => resolve(originalFetch(url, options))));
          }
          if (path !== '/responses' || options?.method !== 'POST') return originalFetch(url, options);
          window.answerPosts++;
          if (window.answerPosts === 2) {
            return originalFetch(url, options).then(result => new Promise(resolve => {
              window.releaseLaterAnswer = () => resolve(result);
            }));
          }
          if (window.answerPosts > 2) return originalFetch(url, options);
          return new Promise(resolve => {
            window.releaseAnswer = async () => {
              const result = await originalFetch(url, options);
              window.savedManifestRevision = (await result.clone().json()).manifest_revision;
              resolve(result);
            };
          });
        };
      JS
      fill_in_answer("code_review", "The latest local explanation.")
      page.driver.with_playwright_page { |pw| pw.keyboard.press("Tab") }
      wait_for_js_condition("typeof window.releaseAnswer === 'function'")
      exercise.update!(problem_set: exercise.problem_set.merge("pattern" => FakeService::EXERCISE_PROBLEM_SET.fetch("pattern")),
        section_order: %w[code_review pattern])

      page.execute_script("window.releaseAnswer()")
      wait_for_answers_settled
      wait_for_js_condition("window.heldAdditionReads.length > 0")
      expect(page.evaluate_script("window.savedManifestRevision")).to eq(2)
      expect(page).to have_no_css('[data-section-fold="pattern"]')
      if intervening == :added_unrated
        response.reload.update!(answers: response.answers.merge("pattern" => "Another tab answered the new card."))
      end
      if intervening == :wrong_scope
        expect(page.evaluate_script("window.reconcileOtherScope()")).to be(false)
        expect(page).to have_no_css('[data-section-fold="pattern"]')
        expect(page).to have_button("Submit answers", disabled: true)
      end
      if intervening == :rating_clear
        rate_section("code_review")
        wait_for_js_condition("typeof window.releaseLaterAnswer === 'function'")
      elsif intervening == :advanced
        exercise.update!(problem_set: exercise.problem_set.merge("design_comparison" => FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison")),
          section_order: %w[code_review pattern design_comparison])
      end
      page.execute_script(<<~JS)
        window.holdAdditionReads = false;
        window.heldAdditionReads.splice(0).forEach(release => release());
      JS

      expect(page).to have_css('[data-section-fold="pattern"]')
      wait_for_js
      aggregate_failures do
        expect(page).to have_button("Submit answers", disabled: [ :rating_clear, :advanced, :added_unrated ].include?(intervening))
        expect(page.evaluate_script("window.answerPosts")).to eq(intervening == :rating_clear ? 2 : 1)
        expect(response.reload.answers.fetch("code_review")).to eq("The latest local explanation.")
      end
      if intervening == :added_unrated
        expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
        expect(find('textarea[data-field="pattern"]').value).to eq("Another tab answered the new card.")
      end
      if intervening == :rating_clear
        page.execute_script("window.releaseLaterAnswer()")
        wait_for_js_condition(<<~JS.squish)
          !window.CodeGymSaveStatus.pending() && window.Stimulus.getControllerForElementAndIdentifier(
            document.querySelector('[data-controller~="answer-form"]'), "answer-form").answersConfirmed
        JS
        expect(page).to have_button("Submit answers", disabled: true)
        rate_section("code_review")
        expect_ready_to_submit
        expect(page.evaluate_script("window.answerPosts")).to eq(3)
      end
    end
  end
end
