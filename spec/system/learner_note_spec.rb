require "rails_helper"

# with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "The note box", type: :system, with_csrf: true do
  def pause_browser_clock
    page.driver.with_playwright_page do |pw|
      now = Time.now.to_i * 1000
      pw.clock.install(time: now)
      pw.clock.pause_at(now + 1)
    end
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

  it "keeps edits made during an in-flight save in the latest queued body" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      pause_browser_clock
      page.execute_script(<<~JS)
        const passThrough = window.fetch;
        window.__noteBodies = [];
        window.fetch = (url, options) => {
          if (new URL(String(url), location.href).pathname !== "/learner_note") return passThrough(url, options);
          window.__noteBodies.push(JSON.parse(options.body));
          if (window.__noteBodies.length !== 1) return passThrough(url, options);
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
      advance_browser_clock(800)
      page.driver.with_playwright_page { |pw| pw.clock.resume }
      page.execute_script("window.__releaseNote()")
      wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

      expect(LearnerNote.find_by(user: user)&.body).to eq("The final thought.")
      expect(page.evaluate_script("window.__noteBodies.map((body) => body.learner_note)")).to eq([ "The first thought.", "The final thought." ])
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

  it "starts the review when Submit lands before a note save it held back" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      page.execute_script(<<~JS)
        (() => {
          const passThrough = window.fetch;
          window.__heldNote = [];
          window.__releaseNote = () => {
            window.__noteReleased = true;
            window.__heldNote.forEach((go) => go());
          };
          window.fetch = (url, options) => {
            const pathname = new URL(String(url), location.href).pathname;
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
      wait_for { user.daily_responses.sole.submitted? }
      page.execute_script("window.__releaseNote()")

      expect(page).to have_no_css("#gym-form")
      expect(page).to have_no_css("#leave-held")
    end
  end

    it "does not recreate a reset note when its typing timer fires from the old page" do
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
        type_note("An unsent edit to the old note.")
        response = user.daily_responses.sole
        expect(response.daily_exercise.start_over!(response_id: response.id)).to eq(:cleared)
        advance_browser_clock(800)

        expect(page).to have_css("#save-status", text: I18n.t("flash.responses.stale_answers"))
        expect(LearnerNote.find_by(user: user)).to be_nil
        expect(user.daily_responses).to be_empty
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
