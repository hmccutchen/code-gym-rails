require "rails_helper"

RSpec.describe "Swapping a daily section kind", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  before do
    visit_with_todays_set(user)
    wait_for_js
  end

  def panel(place) = find("#daily-kind-swap-panel-#{place}")

  def open_picker(place)
    within(panel(place)) { find("button.daily-kind-trigger").click }
    expect(page).to have_css("#daily-kind-#{place}-picker", visible: :visible)
  end

  def confirm_swap(place, kind)
    open_picker(place)
    find("#daily-kind-#{place}-#{kind}").click
    within("#daily-kind-#{place}-picker") { click_button "Confirm" }
  end

  it "opens the picker with the current kind checked and the other daily kind disabled with its reason" do
    open_picker(0)

    expect(find("#daily-kind-0-code_review")).to be_checked
    expect(find("#daily-kind-0-design_comparison")).to be_disabled
    expect(page).to have_css("#daily-kind-0-design_comparison-note", text: "Already a daily section")
    expect(page).to have_css("#daily-kind-0-picker", text: I18n.t("daily_kinds.picker.next_set"))
    expect(find("#daily-kind-0-picker")).to have_button("Confirm", disabled: true)
  end

  it "points each radio at its guide, and shows the chosen option's consequences" do
    open_picker(0)
    radio = find("#daily-kind-0-challenge")

    expect(radio["aria-describedby"].split).to include("daily-kind-0-challenge-guide")
    expect(page).to have_css("#daily-kind-0-challenge-guide", visible: :all)

    radio.click
    expect(page).to have_css("#daily-kind-0-challenge-summary", visible: :visible)
    expect(find("#daily-kind-0-picker")).to have_button("Confirm", disabled: false)
  end

  it "saves a swap, shows the server's message and refreshes both pickers with the new version" do
    version = panel(0)["data-version"]
    confirm_swap(0, "challenge")

    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.swap.saved"))
    expect(page).to have_link(I18n.t("daily_kinds.picker.generate_link"))
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
    expect(panel(0)["data-version"]).not_to eq(version)
    expect(panel(1)["data-version"]).to eq(panel(0)["data-version"])
    expect(panel(0)["data-current"]).to eq("challenge")

    open_picker(1)
    expect(find("#daily-kind-1-challenge")).to be_disabled
  end

  it "takes two swaps in a row without a reload" do
    page.execute_script("window.swapPage = true")
    confirm_swap(0, "challenge")
    expect(page).to have_css("#daily-kind-swap-panel-0[data-current='challenge']")

    confirm_swap(1, "pattern")
    expect(page).to have_css("#daily-kind-swap-panel-1[data-current='pattern']")
    expect(user.reload.daily_section_kinds).to eq(%w[challenge pattern])
    expect(page.evaluate_script("window.swapPage")).to be(true)
  end

  it "shows the stale message from another tab's change and keeps the picker open on Confirm" do
    user.update!(section_kind_weights: { "challenge" => 2.0 })
    confirm_swap(0, "architecture")

    expect(page).to have_css("#save-status", text: I18n.t("daily_kinds.swap.refused.stale"))
    expect(page).to have_css("#daily-kind-0-picker", visible: :visible)
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("Confirm")
    expect(user.reload.daily_section_kinds).to eq([])
  end

  it "works from the keyboard: open, arrow to a kind, Escape closes and returns focus" do
    trigger = within(panel(0)) { find("button.daily-kind-trigger") }
    trigger.send_keys(:enter)

    expect(page.evaluate_script("document.activeElement.id")).to eq("daily-kind-0-code_review")
    page.driver.with_playwright_page { |pw| pw.keyboard.press("ArrowDown") }
    expect(page.evaluate_script("document.activeElement.checked && document.activeElement.dataset.state")).to eq("available")
    expect(find("#daily-kind-0-picker")).to have_button("Confirm", disabled: false)

    page.driver.with_playwright_page { |pw| pw.keyboard.press("Escape") }
    expect(page).to have_css("#daily-kind-0-picker", visible: :hidden)
    expect(trigger["aria-expanded"]).to eq("false")
    expect(page.evaluate_script("document.activeElement.classList.contains('daily-kind-trigger')")).to be(true)
    expect(find("#daily-kind-0-code_review", visible: :all)).to be_checked
  end

  it "confirms a keyboard choice with Enter on Confirm" do
    open_picker(0)
    find("#daily-kind-0-challenge").click
    within("#daily-kind-0-picker") { find_button("Confirm").send_keys(:enter) }

    expect(page).to have_css(".daily-kind-reply", text: I18n.t("daily_kinds.swap.saved"))
    expect(user.reload.daily_section_kinds).to eq(%w[challenge design_comparison])
  end
end
