require "rails_helper"

RSpec.describe "Save status", type: :system do
  let(:user) { create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS) }

  # Re-enabling the disabled checkbox reproduces a stale tab, the one case that can post a slot-emptying set.
  def exclude_every_fourth_kind
    ExerciseSection.fourths.each do |kind|
      page.execute_script("document.querySelector('#exclude-#{kind.key}').disabled = false")
      find("#exclude-#{kind.key}").click
    end
  end

  it "reports a dropped connection while answers are auto-saving" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)

      break_the_network
      find(%(textarea[data-field="code_review"]))
        .fill_in(with: "An answer the server is never going to receive.")

      expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.saving_offline"))
      expect(user.daily_responses).to be_empty
    end
  end

  it "replaces a stale answer form when another tab has submitted the day" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)
      exercise = user.daily_exercises.sole
      saved = user.daily_responses.create!(daily_exercise: exercise, date: exercise.date,
        submitted_at: Time.current, answers: { "code_review" => "The answer already submitted" })

      find(%(textarea[data-field="code_review"])).fill_in(with: "This late edit must not replace the submission")

      expect(page).to have_no_css("#gym-form")
      expect(page).to have_content("The answer already submitted")
      expect(saved.reload.answers["code_review"]).to eq("The answer already submitted")
    end
  end

  it "reloads a form left open across a regeneration instead of saving into the new set" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)
      user.daily_exercises.sole.update!(generated_at: 1.minute.from_now)

      find(%(textarea[data-field="code_review"])).fill_in(with: "Text written for the set before it was replaced")

      expect(page).to have_css("#save-status", text: /the set changed/i)
      expect(user.daily_responses).to be_empty
    end
  end

  it "shows a carried explanation on the page the reload lands on" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)
      page.execute_script("window.CodeGymSaveStatus.carry('answers', 'That last change wasn\\'t saved')")

      page.refresh

      expect(page).to have_css("#save-status", text: /that last change wasn't saved/i)
    end
  end

  it "shows a carried explanation only once" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)
      page.execute_script("window.CodeGymSaveStatus.carry('answers', 'That last change wasn\\'t saved')")

      page.refresh
      expect(page).to have_css("#save-status", text: /that last change wasn't saved/i)
      page.refresh

      expect(page).to have_content(/Code Review/i)
      expect(page).to have_no_css("#save-status", visible: true)
    end
  end

  it "keeps a carried explanation off a page it was not about" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)
      page.execute_script("window.CodeGymSaveStatus.carry('answers', 'A message about the dashboard')")

      visit history_path

      expect(page).to have_css("h1")
      expect(page).to have_no_css("#save-status", visible: true)
    end
  end

  it "reloads a stale rated form without restoring a skipped section's discarded rating" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i)
      exercise = user.daily_exercises.sole
      saved = user.daily_responses.create!(daily_exercise: exercise, date: exercise.date,
        submitted_at: Time.current,
        answers: { "code_review" => "The final submitted answer", "pattern" => "" },
        section_ratings: { "code_review" => "right_level" })

      find('textarea[data-field="pattern"]').fill_in(with: "An answer from the stale tab")
      rate_section("pattern", value: "too_hard")

      expect(page).to have_no_css("#gym-form")
      expect(page).to have_content("The final submitted answer")
      expect(page).not_to have_selector(".history-pill", text: "Pattern: too hard")
      expect(saved.reload.answers["pattern"]).to eq("")
      expect(saved.section_ratings).to eq("code_review" => "right_level")
    end
  end

  it "reports the server's own reason when a stale page is refused" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    exclude_every_fourth_kind

    expect(page).to have_css("#save-status", text: /at least one fourth section/i)
    expect(user.reload.excluded_section_kinds).not_to match_array(ExerciseSection.fourths.map(&:key))
  end

  # fetch follows the redirect to the login page, a 200 that would otherwise read as a successful save.
  it "reports a save made after the session ended" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    user.anonymize!
    find("#weight-challenge").set(0)

    expect(page).to have_css("#save-status", exact_text: I18n.t("request.signed_out"))
  end

  # These three controls PATCH the same path, so an unkeyed status would let one control's success hide another's warning.
  it "keeps one control's warning when a different control saves" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    exclude_every_fourth_kind
    expect(page).to have_css("#save-status")

    find("#tz-select", visible: :all).select("Pacific", visible: :all)

    # Waits on the write, not the DOM: the fetch resolves independently of Capybara.
    wait_for { user.reload.time_zone == "America/Los_Angeles" }

    expect(user.reload.time_zone).to eq("America/Los_Angeles")
    expect(page).to have_css("#save-status", text: /at least one fourth section/i)
  end

  it "clears the report once a later save succeeds" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    exclude_every_fourth_kind
    expect(page).to have_css("#save-status")

    # Un-excluding one leaves a kind in the group, so this payload is accepted.
    find("#exclude-#{ExerciseSection.fourths.first.key}").click

    expect(page).to have_no_css("#save-status", visible: true)
    expect(user.reload.excluded_section_kinds)
      .to match_array(ExerciseSection.fourths.drop(1).map(&:key))
  end
end
