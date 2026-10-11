require "rails_helper"

RSpec.describe "Learning track suggestion controls", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  def reviewed_day(date)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Find the issue", "snippet" => "def a; end", "pitched_at" => "junior" } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { "code_review" => "An answer with sufficient detail" }, section_ratings: { "code_review" => "right_level" },
      ai_review: { "code_review" => { "rating" => "solid", "correct" => "Correct" } })
  end

  def own_proposal(answered:)
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels,
                 track_proposals_answered: answered)
    [ 2, 1, 0 ].each { |ago| reviewed_day(Date.current - ago) }
    visit_as(user)
    expect(page).to have_css("#track-proposal", text: "Move Code Review up to senior?")
  end

  def wait_for_saves
    page.driver.with_playwright_page { |pw| pw.wait_for_function("!window.CodeGymSaveStatus.pending()") }
  end

  it "counts an applied proposal" do
    own_proposal(answered: 0)

    within("#track-proposal") { click_button "Apply" }

    expect(page).to have_css("#track-proposal", text: "Done. Your next sets use the new level.")
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("senior")
    expect(user.track_proposals_answered).to eq(1)
  end

  it "counts a dismissed proposal" do
    own_proposal(answered: 0)

    within("#track-proposal") { click_button "Not now" }

    expect(page).to have_css("#track-proposal", text: "Okay. This comes back once there's more to go on.")
    wait_for_saves
    expect(user.reload.track_proposals_answered).to eq(1)
  end

  it "sends a later proposal to the Exercise mix, where the user makes the change" do
    own_proposal(answered: LearningTrack::IN_PLACE_ANSWERS)

    within("#track-proposal") { click_link "Change it in Setup" }

    expect(page).to have_css("#exercise-mix[open]")
    expect(page).to have_text("Code Gym suggested moving Code Review to Senior.")
    within('.mix-difficulty.mix-suggested[data-kind="code_review"]') { choose "Senior" }
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("senior")
  end

  def fail_requests_to(path)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => url.endsWith(#{path.to_json})
        ? Promise.resolve(new Response(JSON.stringify({ errors: ["nope"] }), { status: 500, headers: { "Content-Type": "application/json" } }))
        : originalFetch(url, options);
    JS
  end

  it "counts a dismissal from a proposal that links to Setup" do
    own_proposal(answered: LearningTrack::IN_PLACE_ANSWERS)

    within("#track-proposal") { click_button "Not now" }

    expect(page).to have_css("#track-proposal", text: "Okay. This comes back once there's more to go on.")
    wait_for_saves
    expect(user.reload.track_proposals_answered).to eq(LearningTrack::IN_PLACE_ANSWERS + 1)
  end

  it "counts nothing when the dismissal fails" do
    own_proposal(answered: LearningTrack::IN_PLACE_ANSWERS)
    fail_requests_to(learning_track_dismissal_path)

    within("#track-proposal") { click_button "Not now" }

    expect(page).to have_button("Not now", disabled: false)
    expect(page).to have_link("Change it in Setup")
    wait_for_saves
    expect(user.reload.track_proposals_answered).to eq(LearningTrack::IN_PLACE_ANSWERS)
  end

  it "puts the switch back when its save fails" do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    visit_as(user)
    visit setup_path
    fail_requests_to(profile_path)

    uncheck "Suggest level changes"
    wait_for_saves

    expect(page).to have_checked_field("Suggest level changes")
    expect(user.reload.track_suggestions).to be(true)
  end

  it "returns the switch to the stored value when several quick saves all fail" do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    visit_as(user)
    visit setup_path
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      const held = [];
      const failure = () => new Response(JSON.stringify({ errors: ["nope"] }), { status: 500, headers: { "Content-Type": "application/json" } });
      window.releaseFailures = () => { window.fetch = () => Promise.resolve(failure()); held.forEach((resolve) => resolve(failure())); };
      window.fetch = (url, options) => url.endsWith(#{profile_path.to_json})
        ? new Promise((resolve) => held.push(resolve))
        : originalFetch(url, options);
    JS

    uncheck "Suggest level changes"
    check "Suggest level changes"
    page.execute_script("window.releaseFailures()")
    wait_for_saves

    expect(page).to have_checked_field("Suggest level changes")
    expect(user.reload.track_suggestions).to be(true)
  end

  it "turns suggestions off and on from Setup" do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    visit_as(user)
    visit setup_path

    uncheck "Suggest level changes"
    wait_for_saves
    expect(user.reload.track_suggestions).to be(false)

    check "Suggest level changes"
    wait_for_saves
    expect(user.reload.track_suggestions).to be(true)
  end
end
