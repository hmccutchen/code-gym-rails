require "rails_helper"

RSpec.describe "Learning track proposal saves", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  before do
    stub_const("LearningTrack::INTRODUCED_AT", 1.day.ago)
    user.update!(learning_track: "junior",
                 section_kind_levels: LearningTrack.preset_levels.merge("code_review" => "senior"))
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Find the issue", "snippet" => "def a; end", "pitched_at" => "senior" } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "An answer with sufficient detail" }, section_ratings: { "code_review" => "right_level" },
      ai_review: { "code_review" => { "rating" => "solid", "correct" => "Correct" } })
    visit_as(user)
    expect(page).to have_css("#track-proposal")
    page.execute_script("window.proposalPage = true")
  end

  def remove(kind)
    find(%(#track-proposal [data-kind="#{kind}"] [data-remove-step])).click
  end

  def expect_same_page
    expect(page.evaluate_script("window.proposalPage")).to be(true)
  end

  it "applies only the listed bundle members and tracks the removed-member dismissal as pending" do
    remove("architecture")
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (url.endsWith("/learning_track/dismissal")) {
          return new Promise((resolve) => {
            window.finishDismissal = () => resolve(originalFetch(url, options));
          });
        }
        return originalFetch(url, options);
      };
    JS

    within("#track-proposal") { click_button "Apply" }

    expect(page).to have_css("#track-proposal", text: "Done. Your next sets use the new level.")
    expect(user.reload.section_kind_levels).to eq(
      LearningTrack.preset_levels.transform_values { "senior" }.merge("architecture" => "junior")
    )
    expect(user.track_evidence_cutoffs).not_to have_key("architecture")
    expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(true)
    expect_same_page
    page.execute_script("window.finishDismissal()")
    page.driver.with_playwright_page { |pw| pw.wait_for_function("!window.CodeGymSaveStatus.pending()") }
    expect(user.reload.track_evidence_cutoffs["architecture"]).to eq("level" => "junior", "through" => Date.current.iso8601)
    expect_same_page
  end

  it "sets aside the whole original bundle without changing levels or navigating" do
    original_levels = user.section_kind_levels
    remove("architecture")

    within("#track-proposal") { click_button "Not now" }

    expect(page).to have_css("#track-proposal", text: "Okay. This comes back once there's more to go on.")
    expect(user.reload.section_kind_levels).to eq(original_levels)
    expect(user.track_evidence_cutoffs.keys).to match_array(ExerciseSection.keys - [ "code_review" ])
    expect_same_page
  end

  it "reports a failed Apply and lets the user retry without navigating" do
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    within("#track-proposal") { click_button "Apply" }

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_button("Apply", disabled: false)
    expect(user.reload.section_kind_levels["pattern"]).to eq("junior")
    expect_same_page
  end

  it "keeps Apply disabled after removing every step even when Not now fails" do
    all("#track-proposal [data-remove-step]").each(&:click)
    expect(page).to have_button("Apply", disabled: true)
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    within("#track-proposal") { click_button "Not now" }

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_button("Not now", disabled: false)
    expect(page).to have_button("Apply", disabled: true)
    expect_same_page
  end

  it "waits for registered pending saves before reloading a stale Apply" do
    page.execute_script(<<~JS)
      window.otherSavePending = true;
      window.CodeGymSaveStatus.watch(() => window.otherSavePending);
    JS
    user.update!(locked_section_kinds: [ "pattern" ])

    within("#track-proposal") { click_button "Apply" }

    expect(page).to have_css("#save-status", text: /updated to match/i)
    page.driver.with_playwright_page { |pw| pw.wait_for_timeout(400) }
    expect_same_page
    expect(user.reload.section_kind_levels["pattern"]).to eq("junior")

    page.execute_script("window.otherSavePending = false")
    page.driver.with_playwright_page { |pw| pw.wait_for_function("window.proposalPage === undefined") }
    expect(page).to have_css("#track-proposal")
    expect(page).not_to have_css('#track-proposal [data-kind="pattern"]')
  end
end
