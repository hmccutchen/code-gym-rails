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
end
