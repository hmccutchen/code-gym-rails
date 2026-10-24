require "rails_helper"

RSpec.describe "Account's reminder nudges switch", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| with_push_credentials { example.run } }

  before do
    user.update!(reminder_level: :ready)
    user.push_subscriptions.create!(endpoint: "https://web.push.apple.com/installed", p256dh_key: "p256dh", auth_key: "auth")
    stub_push_apis(permission: "granted")
    visit_as(user)
    visit account_path
    wait_for_js
  end

  def switch = find("input.switch")
  def status_line = find(".switch-status", visible: :all)
  def banner = find("#save-status", visible: :all)

  def reply_to(path, js_reply)
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => url.endsWith(#{path.to_json})
        ? #{js_reply}
        : originalFetch(url, options);
    JS
  end

  it "saves from a tap on the row's text and says Saved" do
    find(".switch-row").click(x: 4, y: 4)
    wait_for { user.reload.reminders_ready_and_nudges? }
    expect(status_line).to have_text("Saved")
    visit account_path
    expect(switch).to be_checked
  end

  it "goes back and reports a failed save" do
    reply_to("/push_subscription", %(Promise.resolve(new Response("", { status: 500 }))))
    find(".switch-row").click(x: 4, y: 4)
    expect(banner).to have_text(I18n.t("save_status.generic"))
    expect(switch).not_to be_checked
    expect(status_line.text).to eq("")
    expect(user.reload.reminders_ready?).to be(true)
  end

  it "goes back and shows the server's reason when reminders were turned off elsewhere" do
    user.update!(reminder_level: :none)
    find(".switch-row").click(x: 4, y: 4)
    expect(banner).to have_text(I18n.t("accounts.push_reminders.nudges_unavailable"))
    expect(switch).not_to be_checked
    expect(status_line.text).to eq("")
  end

  it "goes back without Saved when the session has ended" do
    reply_to("/push_subscription", "Promise.resolve({ redirected: true })")
    find(".switch-row").click(x: 4, y: 4)
    expect(banner).to be_visible
    expect(switch).not_to be_checked
    expect(status_line.text).to eq("")
  end

  it "ends two quick taps on the second state and says Saved once" do
    switch.click
    switch.click
    wait_for { !page.evaluate_script("window.CodeGymSaveStatus.queued('nudges')") }
    expect(switch).not_to be_checked
    expect(user.reload.reminders_ready?).to be(true)
    expect(status_line).to have_text("Saved", exact: true)
  end

  it "ignores Enter on the switch" do
    switch.send_keys(:enter)
    expect(page).to have_current_path(account_path)
    expect(page).to have_no_text(I18n.t("flash.push_subscriptions.settings_saved"), wait: 0.5)
    expect(switch).not_to be_checked
    expect(user.reload.reminders_ready?).to be(true)
    expect(status_line.text).to eq("")

    switch.send_keys(:space)
    wait_for { user.reload.reminders_ready_and_nudges? }
    expect(status_line).to have_text("Saved")
  end
end
