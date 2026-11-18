require "rails_helper"

# with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "The note box", type: :system, with_csrf: true do
  def pause_browser_clock
    page.driver.with_playwright_page { |pw| pw.clock.pause_at(Time.now.to_i * 1000) }
  end

  def advance_browser_clock(milliseconds)
    page.driver.with_playwright_page { |pw| pw.clock.run_for(milliseconds) }
  end

  def type_note(text)
    page.execute_script(<<~JS)
      (() => {
        const input = document.querySelector("#learner-note textarea");
        input.value = #{text.to_json};
        input.dispatchEvent(new Event("input", { bubbles: true }));
      })();
    JS
  end

  it "saves only the final text after a typing pause even when replies are immediate" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      pause_browser_clock
      page.execute_script("window.__noteBodies = []")
      stub_fetch(learner_note_path, <<~JS)
        (window.__noteBodies.push(JSON.parse(options.body)),
          Promise.resolve(new Response(JSON.stringify({ question: "The same question", question_key: "default" }),
            { status: 200, headers: { "Content-Type": "application/json" } })))
      JS

      [ "T", "Th", "The loop hid the query." ].each do |text|
        type_note(text)
        advance_browser_clock(200)
      end

      expect(page.evaluate_script("window.__noteBodies")).to be_empty
      expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(true)
      advance_browser_clock(599)
      expect(page.evaluate_script("window.__noteBodies")).to be_empty
      advance_browser_clock(1)
      wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

      expect(page.evaluate_script("window.__noteBodies.map((body) => body.learner_note)")).to eq([ "The loop hid the query." ])
    end
  end

  it "keeps a navigation waiting for the note's unsent text" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      pause_browser_clock
      type_note("The loop hid the query.")
      page.execute_script(<<~JS)
        window.CodeGymSaveStatus.leaveWhenSaved(
          () => window.location.assign(#{history_path.to_json}),
          () => { window.__leaveHeld = true });
      JS
      expect(page).to have_current_path(root_path)
      expect(LearnerNote.find_by(user: user)).to be_nil

      advance_browser_clock(800)
      wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
      advance_browser_clock(200)

      expect(page).to have_current_path(history_path)
      expect(LearnerNote.find_by(user: user)&.body).to eq("The loop hid the query.")
    end
  end

  it "saves the pending final text before posting Submit" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      fill_in_answer("code_review", "It queries once per row in the loop.")
      rate_section("code_review")
      expect_ready_to_submit
      wait_for_answers_settled
      pause_browser_clock
      stub_fetch(learner_note_path, "new Promise((resolve) => { window.__releaseNote = () => resolve(passThrough(url, options)); })")
      type_note("The loop hid the query.")
      page.execute_script("document.querySelector('#gym-form').requestSubmit()")
      wait_for_js_condition("window.__releaseNote")
      expect(user.daily_responses.sole).not_to be_submitted
      expect(page.evaluate_script("document.querySelector('#learner-note textarea').closest('[inert]') !== null")).to be(true)
      page.execute_script("window.__releaseNote()")
      wait_for { user.daily_responses.sole.submitted? }
      advance_browser_clock(800)
      wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

      expect(LearnerNote.find_by(user: user)&.body).to eq("The loop hid the query.")
      expect(user.daily_responses.sole).to be_submitted
      advance_browser_clock(200)
      expect(page).to have_no_css("#gym-form")
    end
  end

  it "saves the note as it is typed, without posting it with the answers" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)

      box = find("#learner-note")
      expect(box).to have_css("label", text: "What was the hardest part of today's set?")
      box.find("textarea").fill_in(with: "The loop hid the query.")

      wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
      expect(LearnerNote.find_by(user: user)&.body).to eq("The loop hid the query.")
      expect(DailyResponse.find_by(user: user)&.answers.to_h.values).not_to include("The loop hid the query.")
    end
  end

  it "cancels a detached box's timer and watches the same controller only once after reconnect" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      pause_browser_clock
      type_note("An edit before reconnect.")
      page.execute_script(<<~JS)
        window.__noteBox = document.querySelector("#learner-note");
        window.__noteParent = window.__noteBox.parentNode;
        window.__noteController = window.Stimulus.getControllerForElementAndIdentifier(window.__noteBox, "learner-note");
        window.__extraWatchers = 0;
        const watch = window.CodeGymSaveStatus.watch;
        window.CodeGymSaveStatus.watch = (probe) => { window.__extraWatchers++; watch(probe); };
        window.__noteBox.remove();
      JS
      wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
      advance_browser_clock(800)
      expect(LearnerNote.find_by(user: user)).to be_nil

      page.execute_script("window.__noteParent.appendChild(window.__noteBox)")
      wait_for_js_condition("window.Stimulus.getControllerForElementAndIdentifier(window.__noteBox, 'learner-note') === window.__noteController")
      expect(page.evaluate_script("window.__extraWatchers")).to eq(0)
      expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(true)
      advance_browser_clock(800)
      wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
      expect(LearnerNote.find_by(user: user)&.body).to eq("An edit before reconnect.")
    end
  end

  [ "", "The original thought." ].each do |original|
    it "resumes a pending edit back to #{original.empty? ? 'an empty box' : 'the original text'} after repeated reconnects" do
      stub_env("LEARNER_NOTES" => "1")
      user = create_fake_provider_user
      user.update!(learner_notes_enabled: true)

      travel_to(a_weekday) do
        visit_with_todays_set(user)
        if original.present?
          LearnerNote.create!(user: user, daily_exercise: user.daily_exercises.sole, body: original)
          visit root_path
          wait_for_js
        end
        pause_browser_clock
        type_note("An autosaved revision.")
        advance_browser_clock(800)
        wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
        expect(LearnerNote.find_by(user: user)&.body).to eq("An autosaved revision.")

        type_note(original)
        page.execute_script(<<~JS)
          window.__noteBox = document.querySelector("#learner-note");
          window.__noteParent = window.__noteBox.parentNode;
          window.__noteController = window.Stimulus.getControllerForElementAndIdentifier(window.__noteBox, "learner-note");
          window.__extraWatchers = 0;
          const watch = window.CodeGymSaveStatus.watch;
          window.CodeGymSaveStatus.watch = (probe) => { window.__extraWatchers++; watch(probe); };
        JS

        2.times do
          page.execute_script("window.__noteBox.remove()")
          wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
          advance_browser_clock(800)
          expect(LearnerNote.find_by(user: user)&.body).to eq("An autosaved revision.")

          page.execute_script("window.__noteParent.appendChild(window.__noteBox)")
          wait_for_js_condition("window.Stimulus.getControllerForElementAndIdentifier(window.__noteBox, 'learner-note') === window.__noteController")
          advance_browser_clock(400)
        end

        expect(page.evaluate_script("window.__extraWatchers")).to eq(0)
        advance_browser_clock(400)
        wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
        expect(LearnerNote.find_by(user: user)&.body).to eq(original)
      end
    end
  end

  it "waits for the latest queued body when Submit flushes another edit during an in-flight save" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      fill_in_answer("code_review", "It queries once per row in the loop.")
      rate_section("code_review")
      expect_ready_to_submit
      wait_for_answers_settled
      pause_browser_clock
      page.execute_script(<<~JS)
        const passThrough = window.fetch;
        window.__noteBodies = [];
        window.fetch = (url, options) => {
          if (new URL(String(url), location.href).pathname !== "/learner_note") return passThrough(url, options);
          window.__noteBodies.push(JSON.parse(options.body));
          return new Promise((resolve) => { window.__releaseNote = () => resolve(passThrough(url, options)); });
        };
      JS
      type_note("The first thought.")
      advance_browser_clock(800)
      wait_for_js_condition("window.__releaseNote")
      type_note("The revised thought.")
      advance_browser_clock(800)
      expect(page.evaluate_script("window.CodeGymSaveStatus.queued('learner_note')")).to be(true)
      type_note("The final thought.")
      page.execute_script("document.querySelector('#submit-answers').click()")
      expect(page).to have_button(I18n.t("dashboard.exercise.submitting"), disabled: true)
      expect(user.daily_responses.sole).not_to be_submitted
      page.driver.with_playwright_page { |pw| pw.clock.resume }
      page.execute_script("window.__releaseNote()")
      wait_for_js_condition("window.__noteBodies.length === 2")

      expect(user.daily_responses.sole).not_to be_submitted
      expect(LearnerNote.find_by(user: user)&.body).to eq("The first thought.")
      expect(page.evaluate_script("window.__noteBodies.map((body) => body.learner_note)")).to eq([ "The first thought.", "The final thought." ])
      page.execute_script("window.__releaseNote()")
      expect(page).to have_no_css("#gym-form")
      expect(LearnerNote.find_by(user: user)&.body).to eq("The final thought.")
      expect(user.daily_responses.sole).to be_submitted
    end
  end

  it "keeps a failed submit-time note save editable and retries it on the next Submit" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      fill_in_answer("code_review", "It queries once per row in the loop.")
      rate_section("code_review")
      expect_ready_to_submit
      wait_for_answers_settled
      pause_browser_clock
      page.execute_script("window.__realFetch = window.fetch")
      fail_requests_to(learner_note_path)
      type_note("The loop hid the query.")
      page.execute_script("document.querySelector('#submit-answers').click()")

      expect(page).to have_css("#save-status", text: "nope")
      expect(page).to have_button(I18n.t("dashboard.exercise.submit"), disabled: false)
      expect(user.daily_responses.sole).not_to be_submitted
      expect(find("#learner-note textarea").value).to eq("The loop hid the query.")
      expect(page.evaluate_script("document.querySelector('#learner-note textarea').closest('[inert]')")).to be_nil
      page.execute_script("window.fetch = window.__realFetch; document.querySelector('#submit-answers').click()")

      wait_for { user.daily_responses.sole.submitted? }
      expect(LearnerNote.find_by(user: user)&.body).to eq("The loop hid the query.")
    end
  end

  [ false, true ].each do |other_failure|
    it "reloads after another tab starts over during a pending note#{' once an unrelated save failure clears' if other_failure}" do
      stub_env("LEARNER_NOTES" => "1")
      user = create_fake_provider_user
      user.update!(learner_notes_enabled: true)
      travel_to(a_weekday) do
        visit_with_todays_set(user)
        fill_in_answer("code_review", "It queries once per row in the loop.")
        rate_section("code_review")
        expect_ready_to_submit
        wait_for_answers_settled
        visit root_path
        wait_for_js
        old_scope = find("[data-answer-form-draft-scope-value]")["data-answer-form-draft-scope-value"]
        second_tab = open_new_window
        within_window(second_tab) do
          visit root_path
          wait_for_js
        end
        pause_browser_clock
        type_note("The old tab's unsent edit.")
        within_window(second_tab) do
          page.execute_script("window.confirm = () => true")
          click_button I18n.t("dashboard.exercise.start_over")
          expect(page).to have_content(I18n.t("flash.responses.answers_cleared"))
        end
        page.execute_script("window.CodeGymSaveStatus.report('other_control', 'Another change has not saved.')") if other_failure
        page.execute_script("document.querySelector('#submit-answers').click()")
        page.driver.with_playwright_page { |pw| pw.clock.resume }

        if other_failure
          expect(page).to have_css("#leave-held")
          expect(page).to have_css(%([data-answer-form-draft-scope-value="#{old_scope}"]))
          expect(user.daily_responses).to be_empty
          page.execute_script("window.CodeGymSaveStatus.clear('other_control')")
        end
        expect(page).to have_no_css(%([data-answer-form-draft-scope-value="#{old_scope}"]))
        expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.stale_reloaded"))
        expect(LearnerNote.find_by(user: user)).to be_nil
        expect(user.daily_responses).to be_empty
      end
    end
  end

  it "waits for an in-flight note before posting Submit, including a second Submit click" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      page.execute_script(<<~JS)
        (() => {
          const passThrough = window.fetch;
          window.__heldNote = [];
          window.__submits = 0;
          window.__releaseNote = () => {
            window.__noteReleased = true;
            window.__heldNote.forEach((go) => go());
          };
          window.fetch = (url, options) => {
            const pathname = new URL(String(url), location.href).pathname;
            if (pathname === "/responses" && JSON.parse(options.body).response.submit) {
              window.__submits++;
              return passThrough(url, options).then((response) =>
                new Promise((resolve) => { window.__releaseSubmit = () => resolve(response); }));
            }
            if (pathname !== "/learner_note" || window.__noteReleased) return passThrough(url, options);
            return new Promise((resolve) => window.__heldNote.push(() => resolve(passThrough(url, options))));
          };
        })();
      JS
      fill_in_answer("code_review", "It queries once per row in the loop.")
      rate_section("code_review")
      expect_ready_to_submit
      wait_for_answers_settled
      find("#learner-note textarea").fill_in(with: "The loop hid the query.")
      wait_for_js_condition("window.__heldNote.length > 0")

      click_button I18n.t("dashboard.exercise.submit")
      page.execute_script("document.querySelector('#gym-form').requestSubmit()")
      expect(page).to have_button(I18n.t("dashboard.exercise.submitting"), disabled: true)
      expect(page).to have_no_css("#leave-held", wait: 0.2)
      expect(page.evaluate_script("window.__submits")).to eq(0)
      expect(user.daily_responses.sole).not_to be_submitted
      page.execute_script("window.__releaseNote()")

      wait_for_js_condition("window.__releaseSubmit")
      expect(user.daily_responses.sole).to be_submitted
      expect(page.evaluate_script("window.__submits")).to eq(1)
      expect(LearnerNote.find_by(user: user)&.body).to eq("The loop hid the query.")
      page.execute_script("window.__releaseSubmit()")
      expect(page).to have_no_css("#gym-form")
      expect(page).to have_no_css("#leave-held")
    end
  end

  [ [ "offline", "The final thought.", FetchStubHelper::OFFLINE_REPLY ],
    [ "server error", "", FetchStubHelper::SERVER_ERROR_REPLY ] ].each do |failure, text, reply|
    it "retries an ordinary #{failure} only on Submit and keeps a failed retry editable" do
      stub_env("LEARNER_NOTES" => "1")
      user = create_fake_provider_user
      user.update!(learner_notes_enabled: true)

      travel_to(a_weekday) do
        visit_with_todays_set(user)
        fill_in_answer("code_review", "It queries once per row in the loop.")
        rate_section("code_review")
        expect_ready_to_submit
        wait_for_answers_settled
        type_note("The saved thought.")
        wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
        pause_browser_clock
        page.execute_script("window.__noteBodies = []; window.__failNote = true")
        stub_fetch(learner_note_path, <<~JS)
          (window.__noteBodies.push(JSON.parse(options.body).learner_note),
            window.__failNote ? #{reply} :
              new Promise((resolve) => { window.__releaseNote = () => resolve(passThrough(url, options)); }))
        JS
        type_note(text)
        advance_browser_clock(800)
        wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
        error = failure == "offline" ? page.evaluate_script("document.body.dataset.saveFailedText") : "nope"
        expect(page).to have_css("#save-status", text: error)
        advance_browser_clock(30_000)
        expect(page.evaluate_script("window.__noteBodies")).to eq([ text ])

        page.execute_script("document.querySelector('#submit-answers').click()")
        expect(page).to have_button(I18n.t("dashboard.exercise.submit"), disabled: false)
        expect(page.evaluate_script("window.__noteBodies")).to eq([ text, text ])
        expect(page).to have_css("#save-status", text: error)
        expect(user.daily_responses.sole).not_to be_submitted
        expect(find("#learner-note textarea").value).to eq(text)
        expect(page.evaluate_script("document.querySelector('#learner-note textarea').closest('[inert]')")).to be_nil
        expect(page.evaluate_script("document.querySelector('#gym-form').inert")).to be(false)

        page.execute_script("window.__failNote = false; document.querySelector('#submit-answers').click()")
        wait_for_js_condition("window.__releaseNote")
        expect(user.daily_responses.sole).not_to be_submitted
        expect(page.evaluate_script("window.__noteBodies")).to eq([ text, text, text ])
        page.driver.with_playwright_page { |pw| pw.clock.resume }
        page.execute_script("window.__releaseNote()")
        expect(page).to have_no_css("#gym-form")
        expect(LearnerNote.find_by(user: user)&.body).to eq(text)
        expect(user.daily_responses.sole).to be_submitted
        expect(page).to have_no_css("#save-status")
      end
    end
  end

  [ false, true ].each do |newer_edit|
    it "unlocks Submit when the #{newer_edit ? 'latest queued' : 'in-flight'} note fails without retrying it automatically" do
      stub_env("LEARNER_NOTES" => "1")
      user = create_fake_provider_user
      user.update!(learner_notes_enabled: true)

      travel_to(a_weekday) do
        visit_with_todays_set(user)
        fill_in_answer("code_review", "It queries once per row in the loop.")
        rate_section("code_review")
        expect_ready_to_submit
        wait_for_answers_settled
        pause_browser_clock
        page.execute_script("window.__noteBodies = []; window.__failNote = true")
        stub_fetch(learner_note_path, <<~JS)
          (window.__noteBodies.push(JSON.parse(options.body).learner_note),
            new Promise((resolve) => {
              window.__releaseNote = () => resolve(window.__failNote ? #{FetchStubHelper::SERVER_ERROR_REPLY} : passThrough(url, options));
            }))
        JS
        type_note("The first thought.")
        advance_browser_clock(800)
        wait_for_js_condition("window.__releaseNote")
        if newer_edit
          type_note("The latest thought.")
          advance_browser_clock(800)
          expect(page.evaluate_script("window.CodeGymSaveStatus.queued('learner_note')")).to be(true)
        end
        page.execute_script("document.querySelector('#submit-answers').click()")
        expect(page).to have_button(I18n.t("dashboard.exercise.submitting"), disabled: true)
        expect(user.daily_responses.sole).not_to be_submitted

        if newer_edit
          page.execute_script("window.__failNote = false; window.__releaseNote()")
          wait_for { LearnerNote.find_by(user: user)&.body == "The first thought." }
          advance_browser_clock(1)
          wait_for_js_condition("window.__noteBodies.length === 2")
          expect(user.daily_responses.sole).not_to be_submitted
          expect(page).to have_button(I18n.t("dashboard.exercise.submitting"), disabled: true)
        end
        page.execute_script("window.__failNote = true; window.__releaseNote()")
        expect(page).to have_button(I18n.t("dashboard.exercise.submit"), disabled: false)
        expect(page).to have_css("#save-status", text: "nope")
        expect(user.daily_responses.sole).not_to be_submitted
        expect(page.evaluate_script("document.querySelector('#learner-note textarea').closest('[inert]')")).to be_nil
        expected = newer_edit ? [ "The first thought.", "The latest thought." ] : [ "The first thought." ]
        advance_browser_clock(30_000)
        expect(page.evaluate_script("window.__noteBodies")).to eq(expected)

        page.execute_script("window.__failNote = false; document.querySelector('#submit-answers').click()")
        wait_for_js_condition("window.__noteBodies.length === #{expected.length + 1}")
        page.driver.with_playwright_page { |pw| pw.clock.resume }
        page.execute_script("window.__releaseNote()")
        expect(page).to have_no_css("#gym-form")
        expect(LearnerNote.find_by(user: user)&.body).to eq(expected.last)
        expect(user.daily_responses.sole).to be_submitted
      end
    end
  end

  it "does not resend a successfully autosaved note after refused Submits" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      page.execute_script("window.__noteBodies = []")
      stub_fetch(learner_note_path, "(window.__noteBodies.push(JSON.parse(options.body).learner_note), passThrough(url, options))")
      type_note("The saved thought.")
      wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
      2.times do
        click_button I18n.t("dashboard.exercise.submit")
        expect(page).to have_button(I18n.t("dashboard.exercise.submit"), disabled: false)
      end

      expect(page.evaluate_script("window.__noteBodies")).to eq([ "The saved thought." ])
      expect(LearnerNote.find_by(user: user)&.body).to eq("The saved thought.")
      expect(user.daily_responses.where.not(submitted_at: nil)).to be_empty
    end
  end

  it "keeps a timer's stale refusal for Submit to reload without retrying or posting answers" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      fill_in_answer("code_review", "It queries once per row in the loop.")
      type_note("A note for the old response.")
      wait_for_answers_settled
      visit root_path
      wait_for_js
      pause_browser_clock
      page.execute_script("window.__noteSaves = 0")
      stub_fetch(learner_note_path, "(window.__noteSaves++, passThrough(url, options))")
      type_note("An unsent edit to the old note.")
      response = user.daily_responses.sole
      expect(response.daily_exercise.start_over!(response_id: response.id)).to eq(:cleared)
      advance_browser_clock(800)

      expect(page).to have_css("#save-status", text: I18n.t("flash.responses.stale_answers"))
      expect(LearnerNote.find_by(user: user)).to be_nil
      expect(user.daily_responses).to be_empty
      page.execute_script("window.__submits = 0")
      stub_fetch(responses_path, "(window.__submits++, passThrough(url, options))")
      page.execute_script("window.CodeGymSaveStatus.report('other_control', 'Another change has not saved.'); document.querySelector('#submit-answers').click()")
      page.driver.with_playwright_page { |pw| pw.clock.resume }
      expect(page).to have_css("#leave-held")
      expect(page.evaluate_script("window.__noteSaves")).to eq(1)
      expect(page.evaluate_script("window.__submits")).to eq(0)
      expect(user.daily_responses).to be_empty
      page.execute_script("window.CodeGymSaveStatus.clear('other_control')")
      expect(page).to have_no_css("#leave-held")
      expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.stale_reloaded"))
    end
  end

  it "settles a pending note flush refused because another tab already submitted" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      fill_in_answer("code_review", "It queries once per row in the loop.")
      rate_section("code_review")
      expect_ready_to_submit
      wait_for_answers_settled
      pause_browser_clock
      type_note("The old tab's unsent edit.")
      user.daily_responses.sole.update!(submitted_at: Time.current)
      page.execute_script("document.querySelector('#submit-answers').click()")

      expect(page).to have_no_css("#gym-form")
      expect(page).to have_no_css("#leave-held")
      expect(LearnerNote.find_by(user: user)).to be_nil
    end
  end
end
