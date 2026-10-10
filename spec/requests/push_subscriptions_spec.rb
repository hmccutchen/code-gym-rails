require "rails_helper"

RSpec.describe "Push subscriptions", type: :request do
  let(:user) { create_user_with_key }

  def configure_vapid
    ENV["VAPID_PUBLIC_KEY"] = "public"
    ENV["VAPID_PRIVATE_KEY"] = "private"
  end

  after do
    ENV.delete("VAPID_PUBLIC_KEY")
    ENV.delete("VAPID_PRIVATE_KEY")
  end

  def valid_params
    { endpoint: "https://fcm.googleapis.com/fcm/send/abc", p256dh: "p256", auth: "auth" }
  end

  describe "POST /push_subscription" do
    it "records the endpoint and turns reminders on" do
      configure_vapid
      login_as(user)

      post push_subscription_path, params: valid_params

      expect(response).to have_http_status(:created)
      expect(user.reload.reminders_ready?).to be(true)
      expect(user.push_subscriptions.sole.endpoint).to eq("https://fcm.googleapis.com/fcm/send/abc")
    end

    # Held at the boundary so PushDelivery can assume an endpoint it can sign for.
    [
      [ "a non-https endpoint", { endpoint: "http://fcm.googleapis.com/fcm/send/abc" } ],
      [ "a missing endpoint",   { endpoint: "" } ],
      [ "a missing p256dh key", { p256dh: "" } ],
      [ "a missing auth key",   { auth: "" } ]
    ].each do |description, override|
      it "rejects #{description}" do
        configure_vapid
        login_as(user)

        post push_subscription_path, params: valid_params.merge(override)

        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.reminders_none?).to be(true)
      end
    end

    # Postgres varchar is unlimited and 2048 bytes fits under the unique index's btree limit; drive both.
    it "stores an endpoint at the full permitted length" do
      configure_vapid
      login_as(user)
      prefix   = "https://fcm.googleapis.com/fcm/send/"
      endpoint = prefix + ("a" * (PushSubscriptionsController::MAX_ENDPOINT_LENGTH - prefix.length))
      expect(endpoint.length).to eq(PushSubscriptionsController::MAX_ENDPOINT_LENGTH)

      post push_subscription_path, params: valid_params.merge(endpoint: endpoint)

      expect(response).to have_http_status(:created)
      expect(user.push_subscriptions.sole.endpoint).to eq(endpoint)
    end

    it "rejects an endpoint longer than the column can be trusted to hold" do
      configure_vapid
      login_as(user)

      post push_subscription_path, params: valid_params.merge(endpoint: "https://fcm.googleapis.com/#{'a' * 3000}")

      expect(response).to have_http_status(:unprocessable_content)
    end

    # Accepting any URL would give a logged-in user a blind SSRF: the worker POSTs to whatever is stored.
    [
      [ "an internal host",        "https://10.0.0.5/hook" ],
      [ "localhost",               "https://localhost:5432/hook" ],
      [ "cloud metadata",          "https://169.254.169.254/latest/meta-data/" ],
      [ "an attacker's domain",    "https://evil.example.com/collect" ],
      [ "a lookalike suffix",      "https://fcm.googleapis.com.evil.example/collect" ]
    ].each do |description, endpoint|
      it "refuses an endpoint on #{description}" do
        configure_vapid
        login_as(user)

        post push_subscription_path, params: valid_params.merge(endpoint: endpoint)

        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.reminders_none?).to be(true)
        expect(PushSubscription.count).to eq(0)
      end
    end

    # Suffix matching, so per-region and per-tenant subdomains work without listing each one.
    [
      "https://fcm.googleapis.com/fcm/send/abc",
      "https://updates.push.services.mozilla.com/wpush/v2/abc",
      "https://web.push.apple.com/abc",
      "https://par02p.notify.windows.com/w/?token=abc"
    ].each do |endpoint|
      it "accepts a real push service endpoint (#{URI.parse(endpoint).host})" do
        configure_vapid
        login_as(user)

        post push_subscription_path, params: valid_params.merge(endpoint: endpoint)

        expect(response).to have_http_status(:created)
        expect(user.push_subscriptions.sole.endpoint).to eq(endpoint)
      end
    end

    it "refuses when no VAPID keypair is configured" do
      login_as(user)

      post push_subscription_path, params: valid_params

      expect(response).to have_http_status(:not_found)
      expect(user.reload.reminders_none?).to be(true)
    end

    it "requires a logged-in user" do
      configure_vapid

      post push_subscription_path, params: valid_params

      expect(response).to redirect_to(login_path)
    end

    it "does not walk a nudges user back to ready when their browser re-enrols" do
      configure_vapid
      login_as(user)
      user.update!(reminder_level: :ready_and_nudges)

      post push_subscription_path, params: {
        endpoint: "https://fcm.googleapis.com/fcm/send/abc", p256dh: "p", auth: "a"
      }

      expect(user.reload.reminders_ready_and_nudges?).to be(true)
    end
  end

  describe "PATCH /push_subscription" do
    before { user.update!(reminder_level: :ready) }

    it "opts an enrolled user into nudges" do
      configure_vapid
      login_as(user)

      patch push_subscription_path, params: { nudges: "1" }
      expect(user.reload.reminders_ready_and_nudges?).to be(true)
    end

    it "opts them back out without un-enrolling them" do
      configure_vapid
      login_as(user)
      user.update!(reminder_level: :ready_and_nudges)

      patch push_subscription_path, params: { nudges: "0" }
      expect(user.reload.reminders_ready?).to be(true)
    end

    # iOS grants permission only inside a click handler, so this form post must never enrol from nothing.
    it "cannot enrol a user who has never turned reminders on" do
      configure_vapid
      login_as(user)
      user.update!(reminder_level: :none)

      patch push_subscription_path, params: { nudges: "1" }
      expect(user.reload.reminders_none?).to be(true)
    end

    it "refuses when no VAPID keypair is configured" do
      login_as(user)

      patch push_subscription_path, params: { nudges: "1" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /push_subscription" do
    # Rows left behind would keep the job pushing to a browser whose owner asked it to stop.
    it "drops the endpoints as well as the intent" do
      configure_vapid
      login_as(user)
      post push_subscription_path, params: valid_params

      delete push_subscription_path

      expect(response).to redirect_to(account_path)
      expect(user.reload.reminders_none?).to be(true)
      expect(user.push_subscriptions).to be_empty
    end
  end

  describe "the Account page control" do
    it "offers the toggle where a keypair is configured" do
      configure_vapid
      login_as(user)

      get account_path

      expect(response.body).to include("Turn on daily reminders")
    end

    # An unconfigured deployment must not offer a control that could only fail.
    it "says nothing about reminders where none is configured" do
      login_as(user)

      get account_path

      expect(response.body).not_to include("Turn on daily reminders")
    end

    # iOS prompts only for a synchronous request inside the click, so the key must be in the page, not fetched.
    it "embeds the VAPID public key rather than leaving the click to fetch it" do
      configure_vapid
      login_as(user)

      get account_path

      expect(response.body).to include("const VAPID_KEY = \"public\"")
    end

    # fetch resolves for a 4xx and follows a logged-out redirect to a 200, so both must count as failure.
    it "treats a rejected or redirected enrolment as a failure, not a success" do
      configure_vapid
      login_as(user)

      get account_path

      expect(response.body).to include("redirect: \"error\"")
      expect(response.body).to include("if (!response.ok) throw CodeGymServerMessage.error(")
    end

    # The launch re-subscribe is the only repair for an endpoint iOS dropped.
    it "re-subscribes on launch for a user who has reminders on" do
      configure_vapid
      user.update!(reminder_level: :ready)
      login_as(user)

      get account_path

      expect(response.body).to include("CodeGymPush.subscribeAndRegister()")
    end

    it "emits no push script for a logged-out visitor" do
      configure_vapid

      get login_path

      expect(response.body).not_to include("CodeGymPush")
    end

    it "renders the nudge opt-in on the Account page once enrolled" do
      configure_vapid
      login_as(user)
      user.update!(reminder_level: :ready)

      get account_path

      expect(response.body).to include("Also remind me during the day")
    end
  end

  describe "GET /service-worker.js" do
    it "serves the worker from the root scope, without a session" do
      get "/service-worker.js"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("addEventListener(\"push\"")
    end
  end
end
