require "rails_helper"

# Background saves used to swallow every failure: the fetch promise was never
# consumed, so a rejected write left the control showing a state the server had
# refused. A request spec cannot see that — it exercises the endpoint, not the
# page's handling of the answer — so these drive a real browser and assert what
# the engineer is actually told.
RSpec.describe "Save status", type: :system do
  let(:user) { create_fake_provider_user }

  def break_the_network
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")
  end

  # Unreachable by clicking, which is the point: the last un-excluded kind in a
  # group has its checkbox disabled. Stripping that attribute reproduces a tab
  # whose DOM predates another tab's exclusions — the one case that can post a
  # slot-emptying set and earn a real 422.
  def exclude_every_fourth_kind
    ExerciseSection.fourths.each do |kind|
      page.execute_script("document.querySelector('#exclude-#{kind.key}').disabled = false")
      find("#exclude-#{kind.key}").click
    end
  end

  it "reports a dropped connection while answers are auto-saving" do
    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      break_the_network
      find(%(textarea[data-field="code_review"]))
        .fill_in(with: "An answer the server is never going to receive.")

      expect(page).to have_css("#save-status", text: /couldn't save/i, wait: 5)
      expect(user.daily_responses).to be_empty
    end
  end

  it "replaces a stale answer form when another tab has submitted the day" do
    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)
      exercise = user.daily_exercises.sole
      saved = user.daily_responses.create!(daily_exercise: exercise, date: exercise.date,
        submitted_at: Time.current, answers: { "code_review" => "The answer already submitted" })

      find(%(textarea[data-field="code_review"])).fill_in(with: "This late edit must not replace the submission")

      expect(page).to have_no_css("#gym-form", wait: 10)
      expect(page).to have_content("The answer already submitted")
      expect(saved.reload.answers["code_review"]).to eq("The answer already submitted")
    end
  end

  it "reports the server's own reason when a stale page is refused" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    exclude_every_fourth_kind

    expect(page).to have_css("#save-status", text: /at least one fourth section/i, wait: 5)
    expect(user.reload.excluded_section_kinds).not_to match_array(ExerciseSection.fourths.map(&:key))
  end

  # fetch follows redirects, so a save made after the session ended arrives as
  # the login page: 200, and `ok` true. Taken at face value that reads as a
  # successful write of something the server never stored — the failure this
  # file exists to stop, wearing a success.
  it "reports a save made after the session ended" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    user.anonymize!
    find("#weight-challenge").set(0)

    expect(page).to have_css("#save-status", text: /signed out/i, wait: 5)
  end

  # One banner, but a failure belongs to the control that earned it: these
  # three PATCH the same path, so an unkeyed status would let the time zone's
  # success speak for the exercise mix.
  it "keeps one control's warning when a different control saves" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    exclude_every_fourth_kind
    expect(page).to have_css("#save-status", wait: 5)

    find("#tz-select").select("Pacific")

    # Waits on the write rather than the DOM: the fetch resolves independently
    # of Capybara, and the point is that this save really did succeed.
    deadline = Time.current + 5
    sleep 0.1 until user.reload.time_zone == "America/Los_Angeles" || Time.current > deadline

    expect(user.reload.time_zone).to eq("America/Los_Angeles")
    expect(page).to have_css("#save-status", text: /at least one fourth section/i)
  end

  it "clears the report once a later save succeeds" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    exclude_every_fourth_kind
    expect(page).to have_css("#save-status", wait: 5)

    # Un-excluding one leaves a kind in the group, so this payload is accepted.
    find("#exclude-#{ExerciseSection.fourths.first.key}").click

    expect(page).to have_no_css("#save-status", visible: true, wait: 5)
    expect(user.reload.excluded_section_kinds)
      .to match_array(ExerciseSection.fourths.drop(1).map(&:key))
  end
end
