require "rails_helper"

RSpec.describe "Allowing notifications on a device after reminders are already on", type: :system do
  let(:user) { create_fake_provider_user.tap { |user| user.update!(reminder_level: "ready_and_nudges") } }
  let(:old_endpoint) { "https://web.push.apple.com/removed-install" }
  let(:new_endpoint) { "https://web.push.apple.com/reinstalled" }

  # Like iOS, subscribe() fails until permission is granted, which only a click on the page can ask for.
  def stub_push_apis(permission:, answer: "granted")
    script = <<~JS
      window.pushPermission = #{permission.to_json};
      const subscription = {
        endpoint: #{new_endpoint.to_json},
        toJSON() { return { endpoint: this.endpoint, keys: { p256dh: "p256dh-key", auth: "auth-key" } }; }
      };
      const pushManager = {
        subscribe: async () => {
          if (window.pushPermission !== "granted") throw new DOMException("Not allowed", "NotAllowedError");
          return subscription;
        },
        getSubscription: async () => null
      };
      Object.defineProperty(navigator, "serviceWorker", {
        configurable: true,
        value: { register: async () => ({ pushManager }), ready: Promise.resolve({ pushManager }) }
      });
      window.PushManager = function PushManager() {};
      Object.defineProperty(Notification, "permission", { configurable: true, get: () => window.pushPermission });
      Notification.requestPermission = () => {
        sessionStorage.setItem("permissionRequests", String(Number(sessionStorage.getItem("permissionRequests")) + 1));
        window.pushPermission = #{answer.to_json};
        return Promise.resolve(window.pushPermission);
      };
    JS
    page.driver.with_playwright_page { |pw| pw.add_init_script(script: script) }
  end

  around do |example|
    ENV["VAPID_PUBLIC_KEY"] = "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U"
    ENV["VAPID_PRIVATE_KEY"] = "private"
    example.run
  ensure
    ENV.delete("VAPID_PUBLIC_KEY")
    ENV.delete("VAPID_PRIVATE_KEY")
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

    Timeout.timeout(10) { sleep 0.1 until user.push_subscriptions.reload.exists?(endpoint: new_endpoint) }
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
  end
end
