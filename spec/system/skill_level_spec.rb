require "rails_helper"

RSpec.describe "Skill level on Setup", type: :system do
  let(:user) { create_fake_provider_user }

  def default_labels
    all("[data-skill-level-label]", visible: :all).map { |label| label.text(:all) }.uniq
  end

  before do
    visit_as(user)
    visit setup_path
  end

  it "saves a new skill level and renames the Exercise mix default options to match" do
    select "Solid", from: "Skill level"

    expect(page).to have_css("[data-skill-level-label]", text: "Your skill level (solid)", visible: :all)
    expect(default_labels).to eq([ "Your skill level (solid)" ])
    expect(user.reload.skill_level).to eq("solid")
    expect(page).to have_current_path(setup_path)
  end

  it "reports a failed save and keeps the labels naming the stored level" do
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    select "Strong", from: "Skill level"

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(default_labels).to eq([ "Your skill level (developing)" ])
    expect(user.reload.skill_level).to eq("developing")
  end
end
