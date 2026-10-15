require "rails_helper"

RSpec.describe "Welcome choices", type: :system do
  let(:user) { create_fake_provider_user(learning_track: nil) }

  it "saves the junior preset before continuing to setup" do
    visit_as(user)
    expect(page).to have_current_path(welcome_path)

    find('[data-track="junior"]').click

    expect(page).to have_current_path(setup_path)
    expect(user.reload.learning_track).to eq("junior")
    expect(user.section_kind_levels).to eq(LearningTrack.preset_levels)
    expect(user.section_kind_preferences_version).to eq(1)
    expect(user.skill_level).to eq("junior")
    expect(user.daily_exercises).to be_empty
  end

  it "asks Experienced for a starting level and saves it with the choice" do
    visit_as(user)
    expect(page).to have_current_path(welcome_path)

    find('[data-track="none"]').click

    expect(page).to have_no_css('[data-track="junior"]')
    expect(page).to have_css("h2", text: "Where should your exercises start?")
    expect(page.evaluate_script("document.activeElement.id")).to eq("welcome-level-title")
    expect(user.reload.learning_track).to be_nil

    find('[data-level="mid_level"]').click

    expect(page).to have_current_path(setup_path)
    expect(user.reload.learning_track).to eq("none")
    expect(user.skill_level).to eq("mid_level")
    expect(user.section_kind_levels).to eq({})
    expect(user.section_kind_preferences_version).to eq(0)
  end

  it "goes back to the first question without saving, with focus on Experienced" do
    visit_as(user)
    find('[data-track="none"]').click
    click_button "Back"

    expect(page).to have_css('[data-track="junior"]')
    expect(page).to have_no_css("[data-level]")
    expect(page.evaluate_script('document.activeElement.dataset.track')).to eq("none")
    expect(user.reload.learning_track).to be_nil
    expect(page).to have_current_path(welcome_path)
  end

  it "keeps the level step and focus on a failed level save" do
    visit_as(user)
    find('[data-track="none"]').click
    page.execute_script("window.originalFetch = window.fetch; window.fetch = () => Promise.reject(new Error('offline'))")

    find('[data-level="senior"]').click

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_css("[data-level]:not(:disabled)", count: 3)
    expect(page.evaluate_script("document.activeElement.dataset.level")).to eq("senior")
    expect(user.reload.learning_track).to be_nil

    page.execute_script("window.fetch = window.originalFetch")
    find('[data-level="senior"]').click
    expect(page).to have_current_path(setup_path)
    expect(user.reload.skill_level).to eq("senior")
  end

  it "returns focus to the pressed level button after a failed save, even when the click did not focus it" do
    visit_as(user)
    find('[data-track="none"]').click
    page.execute_script("window.originalFetch = window.fetch; window.fetch = () => Promise.reject(new Error('offline'))")

    page.execute_script("document.querySelector('[data-level=\"mid_level\"]').dispatchEvent(new MouseEvent('click', { bubbles: true }))")

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_css("[data-level]:not(:disabled)", count: 3)
    expect(page.evaluate_script("document.activeElement.dataset.level")).to eq("mid_level")
  end

  it "reports a failed save and lets the user retry without leaving the question" do
    visit_as(user)
    expect(page).to have_current_path(welcome_path)
    page.execute_script("window.originalFetch = window.fetch; window.fetch = () => Promise.reject(new Error('offline'))")

    find('[data-track="junior"]').click

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_css("[data-track]:not(:disabled)", count: 2)
    expect(page).to have_current_path(welcome_path)
    expect(user.reload.learning_track).to be_nil

    page.execute_script("window.fetch = window.originalFetch")
    find('[data-track="junior"]').click
    expect(page).to have_current_path(setup_path)
    expect(user.reload.learning_track).to eq("junior")
  end
end
