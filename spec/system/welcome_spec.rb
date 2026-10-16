require "rails_helper"

RSpec.describe "Welcome choices", type: :system do
  let(:user) { create_fake_provider_user(track_chosen: false) }

  LevelSuggestion::LADDER.each do |level|
    it "saves the #{level} track and continues to setup" do
      visit_as(user)
      expect(page).to have_current_path(welcome_path)
      wait_for_js

      find("[data-level='#{level}']").click

      expect(page).to have_current_path(setup_path)
      expect(user.reload).to have_attributes(skill_level: level, section_kind_levels: {}, learning_track: "none")
      expect(user.track_chosen_at).to be_present
      expect(user.daily_exercises).to be_empty
    end
  end

  it "reports a failed save, returns focus to the pressed button and lets the user retry" do
    visit_as(user)
    wait_for_js
    page.execute_script("window.originalFetch = window.fetch; window.fetch = () => Promise.reject(new Error('offline'))")

    page.execute_script("document.querySelector('[data-level=\"mid_level\"]').dispatchEvent(new MouseEvent('click', { bubbles: true }))")

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_css("[data-level]:not(:disabled)", count: 3)
    expect(page.evaluate_script("document.activeElement.dataset.level")).to eq("mid_level")
    expect(page).to have_current_path(welcome_path)
    expect(user.reload.track_chosen_at).to be_nil

    page.execute_script("window.fetch = window.originalFetch")
    find("[data-level='mid_level']").click
    expect(page).to have_current_path(setup_path)
    expect(user.reload.skill_level).to eq("mid_level")
  end
end
