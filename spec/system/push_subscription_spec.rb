require "rails_helper"

RSpec.describe "Re-subscribing to push reminders on launch", type: :system do
  let(:user) { create_fake_provider_user.tap { |user| user.update!(reminder_level: "ready") } }
  let(:endpoint) { "https://fcm.googleapis.com/fcm/send/launch-endpoint" }

  # Headless Chromium cannot grant push, so the browser's push APIs are replaced before any page script runs.
  def stub_installed_push_apis
    script = <<~JS
      window.pushPosts = [];
      window.pushSubscribed = false;
      window.unsubscribed = false;
      const subscription = {
        endpoint: #{endpoint.to_json},
        unsubscribe: async () => { window.unsubscribed = true; return true; },
        toJSON() { return { endpoint: this.endpoint, keys: { p256dh: "p256dh-key", auth: "auth-key" } }; }
      };
      const pushManager = {
        subscribe: async () => { window.pushSubscribed = true; return subscription; },
        getSubscription: async () => subscription
      };
      Object.defineProperty(navigator, "serviceWorker", {
        configurable: true,
        value: { register: async () => ({ pushManager }), ready: Promise.resolve({ pushManager }) }
      });
      window.PushManager = function PushManager() {};
      Object.defineProperty(Notification, "permission", { configurable: true, get: () => "granted" });
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (String(url).includes("/push_subscription")) window.pushPosts.push(JSON.parse(options.body));
        return originalFetch(url, options);
      };
    JS
    page.driver.with_playwright_page { |pw| pw.add_init_script(script: script) }
  end

  around { |example| with_push_credentials { example.run } }

  def wait_until_subscribed
    wait_for { page.evaluate_script("window.pushSubscribed") }
  end

  it "registers an endpoint the server does not hold yet" do
    stub_installed_push_apis
    visit_as(user)
    wait_for_js
    wait_until_subscribed

    wait_for { user.push_subscriptions.reload.any? }
    expect(page.evaluate_script("window.pushPosts")).to eq([ { "endpoint" => endpoint, "p256dh" => "p256dh-key", "auth" => "auth-key" } ])
    expect(user.push_subscriptions.reload.pluck(:endpoint, :p256dh_key, :auth_key)).to eq([ [ endpoint, "p256dh-key", "auth-key" ] ])
  end

  def stub_push_apis_subscribed_under_another_key
    script = <<~JS
      window.pushPosts = [];
      window.pushSubscribed = false;
      window.unsubscribed = false;
      const oldSubscription = {
        endpoint: "https://fcm.googleapis.com/fcm/send/old-key-endpoint",
        unsubscribe: async () => { window.unsubscribed = true; current = null; return true; }
      };
      const newSubscription = {
        endpoint: #{endpoint.to_json},
        toJSON() { return { endpoint: this.endpoint, keys: { p256dh: "p256dh-key", auth: "auth-key" } }; }
      };
      let current = oldSubscription;
      const pushManager = {
        subscribe: async () => {
          if (current) throw new DOMException("A subscription with a different applicationServerKey already exists", "InvalidStateError");
          window.pushSubscribed = true;
          current = newSubscription;
          return newSubscription;
        },
        getSubscription: async () => current
      };
      Object.defineProperty(navigator, "serviceWorker", {
        configurable: true,
        value: { register: async () => ({ pushManager }), ready: Promise.resolve({ pushManager }) }
      });
      window.PushManager = function PushManager() {};
      Object.defineProperty(Notification, "permission", { configurable: true, get: () => "granted" });
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (String(url).includes("/push_subscription")) window.pushPosts.push(JSON.parse(options.body));
        return originalFetch(url, options);
      };
    JS
    page.driver.with_playwright_page { |pw| pw.add_init_script(script: script) }
  end

  it "replaces a subscription made with a rotated VAPID key, which the browser would otherwise refuse to resubscribe" do
    stub_push_apis_subscribed_under_another_key
    visit_as(user)
    wait_for_js
    wait_until_subscribed

    wait_for { user.push_subscriptions.reload.any? }
    expect(page.evaluate_script("window.unsubscribed")).to be(true)
    expect(user.push_subscriptions.reload.pluck(:endpoint)).to eq([ endpoint ])
  end

  it "posts nothing for an endpoint the server already holds" do
    user.push_subscriptions.create!(endpoint: endpoint, p256dh_key: "p256dh-key", auth_key: "auth-key")
    stub_installed_push_apis
    visit_as(user)
    wait_for_js
    wait_until_subscribed

    sleep 0.5
    expect(page.evaluate_script("window.pushPosts")).to eq([])
    expect(page.evaluate_script("window.unsubscribed")).to be(false)
    expect(user.push_subscriptions.reload.count).to eq(1)
  end
end
