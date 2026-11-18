require "rails_helper"

# with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "The explain question", type: :system, with_csrf: true do
  def submitted_set(user)
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "Service Objects", "question" => "When?", "concept" => "service_objects" }
      }
    )
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "an answer", "pattern" => "another" },
                          section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
                          submitted_at: Time.current,
                          ai_review: %w[code_review pattern].index_with { { "rating" => "solid", "correct" => "Right" } })
  end

  it "swaps the question's wording for another concept, and the saved box shows the chosen one" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      submitted_set(user)
      visit_as(user)
      wait_for_js

      box = find("#learner-explanation")
      expect(box).to have_css(".learner-explanation-question", text: "In your own words, what does N plus one do?")

      box.find("select").select("Service objects")
      expect(box).to have_css(".learner-explanation-question", text: "In your own words, what does Service objects do?")

      box.find("textarea").fill_in(with: "It keeps one operation in one place.")
      box.click_button("Save")

      expect(page).to have_css("#learner-explanation", text: "It keeps one operation in one place.")
      saved = find("#learner-explanation")
      expect(saved).to have_css(".learner-explanation-question", text: "In your own words, what does Service objects do?")
      expect(saved).to have_no_css("textarea, select, button")
      expect(LearnerNote.find_by(user: user).explain_section).to eq("pattern")
    end
  end

  it "asks for the reply once the explanation is saved, and shows it under the not-a-grade heading" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      submitted_set(user)
      visit_as(user)
      wait_for_js

      box = find("#learner-explanation")
      box.find("textarea").fill_in(with: "It runs one query per row.")
      box.click_button("Save")

      reply = find("#learner-explanation-reply", text: "Feedback on your explanation, not a grade")
      expect(reply).to have_text("What was sound: You named what the concept does.")
      expect(reply).to have_no_text("One thing to correct")
      note = LearnerNote.find_by(user: user)
      expect(note).to have_attributes(explanation_reply: include("correction" => nil))
      expect(LearnerExtraction.for(note.daily_exercise).reply_attempts).to eq(1)
    end
  end

  def explained_set(user, attempts:)
    exercise = submitted_set(user).daily_exercise
    LearnerNote.create!(user: user, daily_exercise: exercise, explain_section: "code_review", explain_concept: "n_plus_one",
                        explain_phrasing: "explain.first", explanation: "One query per row.")
    attempts.times { LearnerExtraction.count_reply_attempt!(exercise) { Time.current } }
    exercise
  end

  it "moves focus to the saved box and announces the reply through one live region outside it" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      submitted_set(user)
      visit_as(user)
      wait_for_js

      find("#learner-explanation textarea").fill_in(with: "It runs one query per row.")
      find("#learner-explanation").click_button("Save")

      expect(page).to have_css("#learner-explanation-reply", text: "Feedback on your explanation, not a grade")
      wait_for_js_condition("document.activeElement?.id === 'learner-explanation-heading'")
      announcer = find("#learner-explanation-announcer", visible: :all)
      expect(announcer[:"aria-live"]).to eq("polite")
      expect(page).to have_css("#learner-explanation-announcer", visible: :all, text: "What was sound: You named what the concept does.")
      expect(page).to have_css("#learner-explanation [aria-live]", count: 0)
    end
  end

  it "moves focus to the new reply after Try again" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      explained_set(user, attempts: 1)
      visit_as(user)
      wait_for_js

      click_button "Try again"

      expect(page).to have_css("#learner-explanation-reply", text: "Feedback on your explanation, not a grade")
      wait_for_js_condition("document.activeElement?.closest('#learner-explanation-reply') !== null")
    end
  end

  it "re-enables Try again after the retry gets no answer" do
    stub_env("LEARNER_NOTES" => "1")
    user = create_fake_provider_user
    user.update!(learner_notes_enabled: true)

    travel_to(a_weekday) do
      explained_set(user, attempts: 1)
      visit_as(user)
      wait_for_js
      expect(page).to have_button("Try again", disabled: false)
      drop_requests_to("/learner_explanation/reply")

      click_button "Try again"

      expect(page).to have_css("#learner-explanation-reply", text: I18n.t("learner_notes.reply.failed"))
      expect(page).to have_button("Try again", disabled: false)
    end
  end
end
