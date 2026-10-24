require "rails_helper"

RSpec.describe "Allowing notifications on a device after reminders are already on", type: :system do
  let(:user) { create_fake_provider_user.tap { |user| user.update!(reminder_level: "ready_and_nudges") } }
  let(:old_endpoint) { "https://web.push.apple.com/removed-install" }
  let(:new_endpoint) { PushApiStubs::REINSTALLED_ENDPOINT }

  around do |example|
    with_push_credentials { example.run }
  end

  before { user.push_subscriptions.create!(endpoint: old_endpoint, p256dh_key: "old-p256dh", auth_key: "old-auth") }

  it "offers the permission prompt on a reinstalled app and enrols it without changing the account's level" do
    stub_push_apis(permission: "default")
    visit_as(user)
    visit account_path
    wait_for_js

    expect(page).to have_text(I18n.t("accounts.push_reminders.enabled"))
    expect(page).to have_text(I18n.t("accounts.push_reminders.repair"))
    click_button I18n.t("accounts.push_reminders.repair_button")

    wait_for { user.push_subscriptions.reload.exists?(endpoint: new_endpoint) }
    expect(page.evaluate_script(%(Number(sessionStorage.getItem("permissionRequests"))))).to eq(1)
    expect(user.reload.reminder_level).to eq("ready_and_nudges")
  end

  it "takes the button away once the prompt is answered with Don't Allow" do
    stub_push_apis(permission: "default", answer: "denied")
    visit_as(user)
    visit account_path
    wait_for_js

    click_button I18n.t("accounts.push_reminders.repair_button")

    expect(page).to have_text(I18n.t("accounts.push_reminders.blocked", app_name: I18n.t("app_name")))
    expect(page).to have_no_button(I18n.t("accounts.push_reminders.repair_button"))
    expect(user.push_subscriptions.reload.pluck(:endpoint)).to eq([ old_endpoint ])
  end

  it "offers nothing on a device that already allowed notifications" do
    stub_push_apis(permission: "granted")
    visit_as(user)
    visit account_path
    wait_for_js

    expect(page).to have_text(I18n.t("accounts.push_reminders.enabled"))
    expect(page).to have_no_button(I18n.t("accounts.push_reminders.repair_button"))
    expect(page).to have_no_text(I18n.t("accounts.push_reminders.repair"))
  end

  it "points to the device settings when notifications are blocked" do
    stub_push_apis(permission: "denied")
    visit_as(user)
    visit account_path
    wait_for_js

    expect(page).to have_text(I18n.t("accounts.push_reminders.blocked", app_name: I18n.t("app_name")))
    expect(page).to have_no_button(I18n.t("accounts.push_reminders.repair_button"))
    expect(note_style("#push-repair-status")).to eq(note_style("section.card p.card-note"))
  end

  def note_style(selector)
    page.evaluate_script(%(((s) => { const c = getComputedStyle(document.querySelector(s)); return [c.fontSize, c.color]; })(#{selector.to_json})))
  end
end
