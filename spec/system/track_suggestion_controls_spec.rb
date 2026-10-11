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
    expect(page).to have_text("Code Gym suggested a level change for Code Review.")
    within('.mix-difficulty.mix-suggested[data-kind="code_review"]') { choose "Senior" }
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("senior")
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
