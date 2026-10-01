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
    expect(user.skill_level).to eq("beginner")
    expect(user.daily_exercises).to be_empty
  end

  it "records Experienced without changing difficulty preferences" do
    visit_as(user)
    expect(page).to have_current_path(welcome_path)

    find('[data-track="none"]').click

    expect(page).to have_current_path(setup_path)
    expect(user.reload.learning_track).to eq("none")
    expect(user.section_kind_levels).to eq({})
    expect(user.section_kind_preferences_version).to eq(0)
    expect(user.skill_level).to eq("developing")
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
