require "rails_helper"

# Only a real browser round trip covers the listener that PATCHes /profile; a request spec stays green without it.
RSpec.describe "Daily sections setting", type: :system do
  let(:user) { create_fake_provider_user }

  # Waits on the write, not the DOM: the fetch resolves independently of Capybara.
  def count_after_save(expected)
    wait_for { user.reload.daily_section_count == expected }
    user.reload.daily_section_count
  end

  def name(key) = I18n.t("sections.#{key}.name")

  def in_every_set
    find("#exercise-mix .mix-group", match: :first, visible: :all).all("span[id^=mix-name-]", visible: :all).map { |span| span.text(:all) }
  end

  it "persists a fixed count across a reload, then goes back to Automatic" do
    visit_as(user)
    visit setup_path

    within("#daily-sections") do
      expect(find_field("Automatic", visible: :all)).to be_checked
      choose "2", allow_label_click: true
    end

    expect(count_after_save(2)).to eq(2)
    wait_for { page.has_css?("#exercise-mix .mix-unplaced-note", visible: :all) }

    visit setup_path

    within("#daily-sections") do
      expect(find_field("2", visible: :all)).to be_checked
      choose "Automatic", allow_label_click: true
    end

    expect(count_after_save(nil)).to be_nil
    wait_for { page.has_no_css?("#exercise-mix .mix-unplaced-note", visible: :all) }

    visit setup_path

    expect(within("#daily-sections") { find_field("Automatic", visible: :all) }).to be_checked
  end

  it "asks for the extra section's kind before saving a larger count, then shows it among the sections in every set" do
    visit_as(user)
    visit setup_path

    find("#daily-sections .segment", text: "3").click
    within("#daily-sections-choice-3") do
      select name("challenge"), from: "Extra section 1", visible: :all
      click_button "Save"
    end

    expect(count_after_save(3)).to eq(3)
    expect(user.reload.daily_section_kinds).to eq(%w[code_review design_comparison challenge])
    wait_for { in_every_set == [ name("code_review"), name("design_comparison"), name("challenge") ] }
    expect(find("#daily-sections-choice-3", visible: :all)).not_to be_visible
  end

  it "asks which daily section to keep before saving a count of 1" do
    visit_as(user)
    visit setup_path

    find("#daily-sections .segment", text: "1").click
    within("#daily-sections-choice-1") do
      choose name("design_comparison"), allow_label_click: true
      click_button "Save"
    end

    expect(count_after_save(1)).to eq(1)
    expect(user.reload.daily_section_kinds).to eq(%w[design_comparison code_review])
    wait_for { in_every_set == [ name("design_comparison") ] }
  end

  it "saves nothing when the chooser is cancelled, and checks the saved count again" do
    visit_as(user)
    visit setup_path

    find("#daily-sections .segment", text: "4").click
    within("#daily-sections-choice-4") { click_button "Cancel" }

    expect(find("#daily-sections-choice-4", visible: :all)).not_to be_visible
    expect(within("#daily-sections") { find_field("Automatic", visible: :all) }).to be_checked
    expect(user.reload.daily_section_count).to be_nil
  end

  it "shows the server's refusal in the chooser and keeps it open" do
    visit_as(user)
    visit setup_path

    find("#daily-sections .segment", text: "4").click
    within("#daily-sections-choice-4") do
      select name("challenge"), from: "Extra section 1", visible: :all
      select name("challenge"), from: "Extra section 2", visible: :all
      click_button "Save"

      expect(page).to have_css("[data-daily-sections-error]", text: "Choose a different kind for each section")
    end
    expect(user.reload.daily_section_count).to be_nil
  end

  it "reopens the saved count's chooser when its segment is tapped again, so its kinds can change" do
    user.update!(daily_section_count: 3, daily_section_kinds: %w[code_review design_comparison pattern])
    visit_as(user)
    visit setup_path
    wait_for_js

    find("#daily-sections .segment", text: "3").click
    within("#daily-sections-choice-3") do
      select name("challenge"), from: "Extra section 1", visible: :all
      click_button "Save"
    end

    wait_for { user.reload.daily_section_kinds == %w[code_review design_comparison challenge] }
    expect(user.reload.daily_section_count).to eq(3)
  end

  it "lands an Exercise mix edit still waiting to send before the layout change it would otherwise lose to a reload" do
    visit_as(user)
    visit setup_path
    wait_for_js
    page.execute_script("document.querySelector('#exercise-mix').open = true")

    page.execute_script(<<~JS)
      const slider = document.getElementById("weight-challenge");
      slider.value = "4";
      slider.dispatchEvent(new Event("input", { bubbles: true }));
      document.querySelector("#daily-sections input[value='1']").click();
      document.querySelector("#daily-sections-choice-1 [data-action~='daily-sections#save']").click();
    JS

    wait_for { user.reload.daily_section_count == 1 }
    wait_for { user.reload.section_kind_weights == { "challenge" => KindPreferences::MULTIPLIERS.last } }
  end

  def count_profile_saves
    page.execute_script(<<~JS)
      const originalFetch = window.fetch
      window.beforeReload = true
      window.profileSaves = 0
      window.fetch = (url, options) => {
        const reply = originalFetch(url, options)
        if (new URL(url, location.href).pathname === "/profile") reply.then(() => { window.profileSaves += 1 })
        return reply
      }
    JS
  end

  def expect_back_on_automatic_without_a_reload
    wait_for_js_condition("window.profileSaves === 2 && !CodeGymSaveStatus.pending()")
    expect(user.reload.daily_section_count).to be_nil
    expect(page.evaluate_script("window.beforeReload")).to be(true)
    expect(page.evaluate_script("document.querySelector(\"#daily-sections input[value='automatic']\").checked")).to be(true)
  end

  it "saves a tap back to the saved count made while the first tap's save is still in flight" do
    visit_as(user)
    visit setup_path
    wait_for_js
    count_profile_saves

    page.execute_script(<<~JS)
      document.querySelector("#daily-sections input[value='2']").click();
      document.querySelector("#daily-sections input[value='automatic']").click();
    JS

    expect_back_on_automatic_without_a_reload
  end

  it "saves a tap back made in a later event while the first tap's reply is still held" do
    visit_as(user)
    visit setup_path
    wait_for_js
    count_profile_saves
    page.execute_script(<<~JS)
      const countingFetch = window.fetch
      window.heldSaves = []
      window.releaseEverySave = () => {
        window.fetch = countingFetch
        window.heldSaves.forEach((save) => save.release())
      }
      window.fetch = (url, options) => {
        if (new URL(url, location.href).pathname !== "/profile") return countingFetch(url, options)
        return new Promise((resolve) => window.heldSaves.push({ release: () => resolve(countingFetch(url, options)) }))
      }
    JS

    find("#daily-sections .segment", text: "2").click
    wait_for_js_condition("window.heldSaves.length === 1")
    find("#daily-sections .segment", text: "Automatic").click
    page.execute_script("window.releaseEverySave()")

    expect_back_on_automatic_without_a_reload
  end
end
