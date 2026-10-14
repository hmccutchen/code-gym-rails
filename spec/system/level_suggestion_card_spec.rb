require "rails_helper"

RSpec.describe "Learning track proposal saves", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  def reviewed_day(date, kinds)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current,
      problem_set: kinds.index_with { { "question" => "Find the issue", "snippet" => "def a; end", "pitched_at" => "junior" } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: kinds.index_with { "An answer with sufficient detail" }, section_ratings: kinds.index_with { "right_level" },
      ai_review: kinds.index_with { { "rating" => "solid", "correct" => "Correct", "rubric" => AiService::RUBRIC_VERSION } })
  end

  # Today holds only code review, so the dashboard renders one section while three kinds have five results each.
  before do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    reviewed_day(Date.current, [ "code_review" ])
    (1...LevelSuggestion::WINDOW).each { |ago| reviewed_day(Date.current - ago, %w[code_review pattern architecture]) }
    reviewed_day(Date.current - LevelSuggestion::WINDOW, %w[pattern architecture])
    visit_as(user)
    expect(page).to have_css("#level-suggestion")
    page.execute_script("window.proposalPage = true")
  end

  def remove(kind)
    find(%(#level-suggestion [data-kind="#{kind}"] [data-remove-step])).click
  end

  def expect_same_page
    expect(page.evaluate_script("window.proposalPage")).to be(true)
  end

  it "applies only the listed kinds and tracks the set-aside kind's dismissal as pending" do
    remove("architecture")
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (url.endsWith("/level_suggestion/dismissal")) {
          return new Promise((resolve) => {
            window.finishDismissal = () => resolve(originalFetch(url, options));
          });
        }
        return originalFetch(url, options);
      };
    JS

    within("#level-suggestion") { click_button "Apply" }

    expect(page).to have_css("#level-suggestion", text: "Done. Your next sets use the new level.")
    expect(user.reload.section_kind_levels).to eq(
      LearningTrack.preset_levels.merge("code_review" => "mid_level", "pattern" => "mid_level")
    )
    expect(user.level_suggestion_cutoffs).not_to have_key("architecture")
    expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(true)
    expect_same_page
    page.execute_script("window.finishDismissal()")
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")
    expect(user.reload.level_suggestion_cutoffs["architecture"]).to eq("level" => "junior", "through" => Date.current.iso8601)
    expect(user.level_suggestion_events.where(kind: "architecture").pluck(:action)).to eq([ "removed" ])
    expect_same_page
  end

  def focused_text
    page.evaluate_script("document.activeElement.getAttribute('role') + ': ' + document.activeElement.textContent")
  end

  # The buttons that had focus are removed, so the confirmation takes it.
  it "moves focus to an announced confirmation after Apply" do
    within("#level-suggestion") { click_button "Apply" }
    expect(page).to have_css("#level-suggestion [role='status']", text: "Done. Your next sets use the new level.")
    expect(focused_text).to eq("status: Done. Your next sets use the new level.")
  end

  it "sets aside every kind the card listed without changing levels or navigating" do
    original_levels = user.section_kind_levels
    remove("architecture")

    within("#level-suggestion") { click_button "Not now" }

    expect(page).to have_css("#level-suggestion", text: "Okay. This comes back once there's more to go on.")
    expect(focused_text).to eq("status: Okay. This comes back once there's more to go on.")
    expect(user.reload.section_kind_levels).to eq(original_levels)
    expect(user.level_suggestion_cutoffs.keys).to match_array(%w[code_review pattern architecture])
    expect(user.level_suggestion_events.pluck(:kind, :action)).to match_array(
      %w[code_review pattern architecture].map { |kind| [ kind, "dismissed" ] }
    )
    expect_same_page
  end

  it "reports a failed Apply and lets the user retry without navigating" do
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    within("#level-suggestion") { click_button "Apply" }

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_button("Apply", disabled: false)
    expect(user.reload.section_kind_levels["pattern"]).to eq("junior")
    expect_same_page
  end

  it "keeps Apply disabled after removing every step even when Not now fails" do
    all("#level-suggestion [data-remove-step]").each(&:click)
    expect(page).to have_button("Apply", disabled: true)
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    within("#level-suggestion") { click_button "Not now" }

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_button("Not now", disabled: false)
    expect(page).to have_button("Apply", disabled: true)
    expect_same_page
  end

  # Timers run at once so the ten-second wait passes immediately.
  it "offers a manual reload when another save is still pending at the wait limit" do
    page.execute_script(<<~JS)
      window.CodeGymSaveStatus.watch(() => true);
      const originalSetTimeout = window.setTimeout;
      window.setTimeout = (callback, _delay, ...args) => originalSetTimeout(callback, 0, ...args);
    JS
    user.update!(locked_section_kinds: [ "pattern" ])

    within("#level-suggestion") { click_button "Apply" }

    expect(page).to have_css("#level-suggestion [role='status']", text: "Your settings changed in another tab")
    expect(page).to have_button("Reload", disabled: false)
    expect(page.evaluate_script("document.activeElement.getAttribute('role')")).to eq("status")
    expect_same_page

    click_button "Reload"
    wait_for_js_condition("window.proposalPage === undefined")
    expect(page).to have_css("#level-suggestion")
  end

  it "waits for registered pending saves before reloading a stale Apply" do
    page.execute_script(<<~JS)
      window.otherSavePending = true;
      window.CodeGymSaveStatus.watch(() => window.otherSavePending);
    JS
    user.update!(locked_section_kinds: [ "pattern" ])

    within("#level-suggestion") { click_button "Apply" }

    expect(page).to have_css("#save-status", text: /updated to match/i)
    page.driver.with_playwright_page { |pw| pw.wait_for_timeout(400) }
    expect_same_page
    expect(user.reload.section_kind_levels["pattern"]).to eq("junior")

    page.execute_script("window.otherSavePending = false")
    wait_for_js_condition("window.proposalPage === undefined")
    expect(page).to have_css("#level-suggestion")
    expect(page).not_to have_css('#level-suggestion [data-kind="pattern"]')
  end
end
