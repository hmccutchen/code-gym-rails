require "rails_helper"

# with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "The note box", type: :system, with_csrf: true do
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
end
