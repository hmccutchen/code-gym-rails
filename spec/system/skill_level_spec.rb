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
    select "Senior", from: "Skill level"

    expect(page).to have_css("[data-skill-level-label]", text: "Your skill level (Senior)", visible: :all)
    expect(default_labels).to eq([ "Your skill level (Senior)" ])
    expect(user.reload.skill_level).to eq("senior")
    expect(page).to have_current_path(setup_path)
  end

  # Two quick changes must reach the server in the order they were made. The
  # first PATCH is held in the browser until after the second change; sent in
  # parallel, it would land last and store the older level.
  it "stores the last of two quick changes even when the first save is slow" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (url.endsWith("/profile") && JSON.parse(options.body).user.skill_level === "senior") {
          return new Promise((resolve) => { window.releaseSenior = () => resolve(originalFetch(url, options)); });
        }
        return originalFetch(url, options);
      };
    JS

    select "Senior", from: "Skill level"
    page.driver.with_playwright_page { |pw| pw.wait_for_function("typeof window.releaseSenior === 'function'") }
    select "Principal", from: "Skill level"
    page.driver.with_playwright_page { |pw| pw.wait_for_timeout(300) }
    page.execute_script("window.releaseSenior()")
    page.driver.with_playwright_page { |pw| pw.wait_for_function("!window.CodeGymSaveStatus.pending()") }

    expect(user.reload.skill_level).to eq("principal_engineer")
    expect(default_labels).to eq([ "Your skill level (Principal)" ])
  end

  it "reports a failed save and keeps the labels naming the stored level" do
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    select "Principal", from: "Skill level"

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(default_labels).to eq([ "Your skill level (Junior)" ])
    expect(user.reload.skill_level).to eq("junior")
  end
end
