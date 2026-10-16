require "rails_helper"

RSpec.describe "Track select on Setup", type: :system do
  let(:user) { create_fake_provider_user }

  def default_labels
    all("[data-skill-level-label]", visible: :all).map { |label| label.text(:all) }.uniq
  end

  before do
    visit_as(user)
    visit setup_path
  end

  it "saves a new track and renames the Exercise mix default options to match" do
    select "Senior", from: "Track"

    expect(page).to have_css("[data-skill-level-label]", text: "Your track (Senior)", visible: :all)
    expect(default_labels).to eq([ "Your track (Senior)" ])
    expect(user.reload.skill_level).to eq("senior")
    expect(page).to have_current_path(setup_path)
  end

  it "holds a second change until the first save lands, then stores it" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (url.endsWith("/profile") && JSON.parse(options.body).user.skill_level === "senior") {
          return new Promise((resolve) => { window.releaseSenior = () => resolve(originalFetch(url, options)); });
        }
        return originalFetch(url, options);
      };
    JS

    select "Senior", from: "Track"
    wait_for_js_condition("typeof window.releaseSenior === 'function'")
    expect(page).to have_css("#skill-level[disabled]")
    page.execute_script("window.releaseSenior()")
    expect(page).to have_css("#skill-level:not([disabled])")
    select "Principal engineer", from: "Track"
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

    expect(user.reload.skill_level).to eq("principal_engineer")
    expect(default_labels).to eq([ "Your track (Principal engineer)" ])
  end

  it "reports a failed save and keeps the labels naming the stored level" do
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    select "Principal engineer", from: "Track"

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(default_labels).to eq([ "Your track (Junior)" ])
    expect(user.reload.skill_level).to eq("junior")
  end
end
