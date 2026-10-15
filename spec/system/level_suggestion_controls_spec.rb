require "rails_helper"

RSpec.describe "Learning track suggestion controls", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  def reviewed_day(date, level:)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Find the issue", "snippet" => "def a; end", "pitched_at" => level } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { "code_review" => "An answer with sufficient detail" }, section_ratings: { "code_review" => "right_level" },
      ai_review: { "code_review" => { "rating" => "solid", "correct" => "Correct", "rubric" => AiService::RUBRIC_VERSION } })
  end

  def qualifying_days
    LevelSuggestion::WINDOW.times { |ago| reviewed_day(Date.current - ago, level: user.section_kind_levels["code_review"]) }
  end

  def own_proposal(answered:)
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels,
                 level_suggestion_answers: answered)
    qualifying_days
    visit_as(user)
    expect(page).to have_css("#level-suggestion", text: "Try Code Review at mid-level?")
  end

  def wait_for_saves
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
  end

  it "counts an applied proposal" do
    own_proposal(answered: 0)

    within("#level-suggestion") { click_button "Apply" }

    expect(page).to have_css("#level-suggestion", text: "Done. Your next sets use the new level.")
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("mid_level")
    expect(user.level_suggestion_answers).to eq(1)
  end

  it "reports no failed save when Apply moves the last kind below senior up and ends the track" do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels.transform_values { "senior" }.merge("code_review" => "mid_level"))
    qualifying_days
    visit_as(user)
    expect(page).to have_css("#level-suggestion", text: "Try Code Review at senior?")

    within("#level-suggestion") { click_button "Apply" }

    expect(page).to have_css("#level-suggestion", text: "Done. Your next sets use the new level.")
    wait_for_saves
    expect(user.reload.learning_track).to eq("none")
    expect(page).to have_css("#save-status", visible: :hidden)
  end

  it "counts a dismissed proposal" do
    own_proposal(answered: 0)

    within("#level-suggestion") { click_button "Not now" }

    expect(page).to have_css("#level-suggestion", text: "Okay. This comes back once there's more to go on.")
    wait_for_saves
    expect(user.reload.level_suggestion_answers).to eq(1)
  end

  it "sends a later proposal to the Exercise mix, where the user makes the change" do
    own_proposal(answered: LevelSuggestion::IN_PLACE_ANSWERS)

    within("#level-suggestion") { click_link "Change it in Setup" }

    expect(page).to have_css("#exercise-mix[open]")
    expect(page).to have_text("Code Gym suggested moving Code Review to mid-level.")
    within('.mix-difficulty.mix-suggested[data-kind="code_review"]') { choose "Mid-level" }
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("mid_level")
    expect(user.level_suggestion_events.sole).to have_attributes(kind: "code_review", source: "suggestion")

    within('.mix-difficulty.mix-suggested[data-kind="code_review"]') { choose "Senior" }
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("senior")
    expect(user.level_suggestion_events.order(:id).last).to have_attributes(source: "setup_edit", to_level: "senior")
  end

  def fail_requests_to(path)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => url.endsWith(#{path.to_json})
        ? Promise.resolve(new Response(JSON.stringify({ status: "error", error: "nope" }), { status: 500, headers: { "Content-Type": "application/json" } }))
        : originalFetch(url, options);
    JS
  end

  {
    "network failure" => "Promise.reject(new Error('offline'))",
    "server refusal" => "Promise.resolve(new Response(JSON.stringify({ status: 'error', error: 'Counter write failed' }), { status: 500 }))",
    "session redirect" => "Promise.resolve({ redirected: true })"
  }.each do |failure, reply|
    [ "Apply", "Not now" ].each do |action|
      it "preserves the saved #{action} result when its counter request has a #{failure}" do
        own_proposal(answered: 0)
        page.execute_script(<<~JS)
          const originalFetch = window.fetch;
          window.fetch = (url, options) => url.endsWith(#{level_suggestion_answer_path.to_json})
            ? #{reply}
            : originalFetch(url, options);
        JS

        within("#level-suggestion") { click_button action }
        wait_for_saves

        expected_level = action == "Apply" ? "mid_level" : "junior"
        expect(user.reload.section_kind_levels["code_review"]).to eq(expected_level)
        expect(user.level_suggestion_cutoffs["code_review"]).to eq("level" => expected_level, "through" => Date.current.iso8601)
        expect(user.level_suggestion_answers).to eq(0)
        confirmation = action == "Apply" ? "Done. Your next sets use the new level." : "Okay. This comes back once there's more to go on."
        expect(page).to have_css("#level-suggestion", text: confirmation)
        expect(page).to have_css("#save-status", text: "Your choice was saved, but we couldn't update the suggestion count. You don't need to repeat it.")
      end
    end
  end

  it "counts a dismissal from a proposal that links to Setup" do
    own_proposal(answered: LevelSuggestion::IN_PLACE_ANSWERS)

    within("#level-suggestion") { click_button "Not now" }

    expect(page).to have_css("#level-suggestion", text: "Okay. This comes back once there's more to go on.")
    wait_for_saves
    expect(user.reload.level_suggestion_answers).to eq(LevelSuggestion::IN_PLACE_ANSWERS + 1)
  end

  it "counts nothing when the dismissal fails" do
    own_proposal(answered: LevelSuggestion::IN_PLACE_ANSWERS)
    fail_requests_to(level_suggestion_dismissal_path)

    within("#level-suggestion") { click_button "Not now" }

    expect(page).to have_button("Not now", disabled: false)
    expect(page).to have_link("Change it in Setup")
    wait_for_saves
    expect(user.reload.level_suggestion_answers).to eq(LevelSuggestion::IN_PLACE_ANSWERS)
  end

  it "puts the switch back when its save fails" do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    visit_as(user)
    visit setup_path(show: "level_suggestions")
    fail_requests_to(profile_path)

    # Not uncheck: the failed save can put the box back before Playwright confirms the click changed it.
    find_field("Suggest level changes").click
    wait_for_saves

    expect(page).to have_checked_field("Suggest level changes")
    expect(user.reload.level_suggestions).to be(true)
  end

  it "returns the switch to the stored value when several quick saves all fail" do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    visit_as(user)
    visit setup_path(show: "level_suggestions")
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      const held = [];
      const failure = () => new Response(JSON.stringify({ status: "error", error: "nope" }), { status: 500, headers: { "Content-Type": "application/json" } });
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
    expect(user.reload.level_suggestions).to be(true)
  end

  it "turns suggestions off and on from Setup" do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    visit_as(user)
    visit setup_path(show: "level_suggestions")

    uncheck "Suggest level changes"
    wait_for_saves
    expect(user.reload.level_suggestions).to be(false)

    check "Suggest level changes"
    wait_for_saves
    expect(user.reload.level_suggestions).to be(true)
  end

  it "opens the Exercise mix at the switch and focuses it when the card's Setup link is followed" do
    own_proposal(answered: 0)

    within("#level-suggestion") { click_link "Setup" }

    expect(page).to have_css("#exercise-mix[open]")
    wait_for_js_condition("document.activeElement && document.activeElement.id === 'level-suggestions'")
    uncheck "Suggest level changes"
    wait_for_saves
    expect(user.reload.level_suggestions).to be(false)
  end

  it "leaves focus alone on a plain visit to Setup" do
    visit_as(user)
    visit setup_path

    expect(page).to have_css("#exercise-mix:not([open])")
    expect(page.evaluate_script("document.activeElement.id")).not_to eq("level-suggestions")
  end

  it "shows the switch to an account that was never on the track" do
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click

    uncheck "Suggest level changes"
    wait_for_saves
    expect(user.reload.level_suggestions).to be(false)
  end

  it "drops a Setup suggestion once a different level is saved for that kind, so a later pick saves" do
    own_proposal(answered: LevelSuggestion::IN_PLACE_ANSWERS)
    within("#level-suggestion") { click_link "Change it in Setup" }
    box = '.mix-difficulty.mix-suggested[data-kind="code_review"]'

    within(box) { choose "Senior" }
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("senior")

    within(box) { choose "Mid-level" }
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("mid_level")
    expect(page).not_to have_css("#save-status", text: /updated to match/i)
    expect(user.level_suggestion_events.order(:id).pluck(:source)).to eq(%w[setup_edit setup_edit])
  end

  it "keeps a Setup suggestion for a kind whose level was not saved differently" do
    own_proposal(answered: LevelSuggestion::IN_PLACE_ANSWERS)
    within("#level-suggestion") { click_link "Change it in Setup" }

    within('.mix-difficulty[data-kind="pattern"]') { choose "Senior" }
    wait_for_saves
    within('.mix-difficulty.mix-suggested[data-kind="code_review"]') { choose "Mid-level" }
    wait_for_saves

    expect(user.level_suggestion_events.find_by(kind: "code_review").source).to eq("suggestion")
  end

  it "keeps a Setup suggestion when a save leaves the kind at the same rung" do
    user.update!(skill_level: "junior", level_suggestion_answers: LevelSuggestion::IN_PLACE_ANSWERS)
    LevelSuggestion::WINDOW.times { |ago| reviewed_day(Date.current - ago, level: "junior") }
    visit_as(user)
    within("#level-suggestion") { click_link "Change it in Setup" }
    box = '.mix-difficulty.mix-suggested[data-kind="code_review"]'

    within(box) { choose "Junior" }
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("junior")

    within(box) { choose "Mid-level" }
    wait_for_saves
    expect(user.reload.section_kind_levels["code_review"]).to eq("mid_level")
    expect(user.level_suggestion_events.where(kind: "code_review").pluck(:source)).to eq(%w[suggestion])
  end
end
