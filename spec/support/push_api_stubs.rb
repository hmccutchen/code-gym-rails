module PushApiStubs
  REINSTALLED_ENDPOINT = "https://web.push.apple.com/reinstalled".freeze

  def with_push_credentials
    ENV["VAPID_PUBLIC_KEY"] = "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U"
    ENV["VAPID_PRIVATE_KEY"] = "private"
    yield
  ensure
    ENV.delete("VAPID_PUBLIC_KEY")
    ENV.delete("VAPID_PRIVATE_KEY")
  end

  # Like iOS, subscribe() fails until permission is granted, which only a click on the page can ask for.
  def stub_push_apis(permission:, answer: "granted")
    script = <<~JS
      window.pushPermission = #{permission.to_json};
      const subscription = {
        endpoint: #{REINSTALLED_ENDPOINT.to_json},
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
end

RSpec.configure do |config|
  config.include PushApiStubs, type: :system
end
