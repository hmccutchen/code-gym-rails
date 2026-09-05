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
    { endpoint: "https://push.example.com/abc", p256dh: "p256", auth: "auth" }
  end

  describe "POST /push_subscription" do
    it "records the endpoint and turns reminders on" do
      configure_vapid
      login_as(user)

      post push_subscription_path, params: valid_params

      expect(response).to have_http_status(:created)
      expect(user.reload.push_reminders_enabled).to be(true)
      expect(user.push_subscriptions.sole.endpoint).to eq("https://push.example.com/abc")
    end

    # Provider-shaped input from the browser, held at the boundary so
    # PushDelivery can assume an endpoint it can actually sign for.
    [
      [ "a non-https endpoint", { endpoint: "http://push.example.com/abc" } ],
      [ "a missing endpoint",   { endpoint: "" } ],
      [ "a missing p256dh key", { p256dh: "" } ],
      [ "a missing auth key",   { auth: "" } ]
    ].each do |description, override|
      it "rejects #{description}" do
        configure_vapid
        login_as(user)

        post push_subscription_path, params: valid_params.merge(override)

        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.push_reminders_enabled).to be(false)
      end
    end

    # Postgres `character varying` with no length specifier is unlimited — the
    # 255-byte default is a MySQL convention, not a Rails one — and 2048 bytes
    # sits under the ~2704-byte btree limit the UNIQUE index on this column
    # imposes. Both halves matter, so this drives a real endpoint at the bound
    # through to a persisted row rather than asserting the column type.
    it "stores an endpoint at the full permitted length" do
      configure_vapid
      login_as(user)
      prefix   = "https://push.example.com/"
      endpoint = prefix + ("a" * (PushSubscriptionsController::MAX_ENDPOINT_LENGTH - prefix.length))
      expect(endpoint.length).to eq(PushSubscriptionsController::MAX_ENDPOINT_LENGTH)

      post push_subscription_path, params: valid_params.merge(endpoint: endpoint)

      expect(response).to have_http_status(:created)
      expect(user.push_subscriptions.sole.endpoint).to eq(endpoint)
    end

    it "rejects an endpoint longer than the column can be trusted to hold" do
      configure_vapid
      login_as(user)

      post push_subscription_path, params: valid_params.merge(endpoint: "https://push.example.com/#{'a' * 3000}")

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses when no VAPID keypair is configured" do
      login_as(user)

      post push_subscription_path, params: valid_params

      expect(response).to have_http_status(:not_found)
      expect(user.reload.push_reminders_enabled).to be(false)
    end

    it "requires a logged-in user" do
      configure_vapid

      post push_subscription_path, params: valid_params

      expect(response).to redirect_to(login_path)
    end
  end

  describe "DELETE /push_subscription" do
    # The endpoints go too, not just the flag: leaving rows behind would keep
    # tomorrow's job pushing at a browser whose owner just asked it to stop.
    it "drops the endpoints as well as the intent" do
      configure_vapid
      login_as(user)
      post push_subscription_path, params: valid_params

      delete push_subscription_path

      expect(response).to redirect_to(account_path)
      expect(user.reload.push_reminders_enabled).to be(false)
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

    # iOS gives a permission prompt only to a request made synchronously inside
    # the click, so nothing the handler needs may be fetched first. Embedding
    # the key in the page is what removes the one round trip that would
    # otherwise have to happen before Notification.requestPermission().
    it "embeds the VAPID public key rather than leaving the click to fetch it" do
      configure_vapid
      login_as(user)

      get account_path

      expect(response.body).to include("const VAPID_KEY = \"public\"")
    end

    # fetch resolves for a 4xx and would follow a logged-out redirect to a 200,
    # so without both of these a rejected enrolment reloads the page looking
    # like success and the user is never told it failed.
    it "treats a rejected or redirected enrolment as a failure, not a success" do
      configure_vapid
      login_as(user)

      get account_path

      expect(response.body).to include("redirect: \"error\"")
      expect(response.body).to include("if (!response.ok) throw new Error")
    end

    # The launch re-subscribe is the whole iOS mitigation: a dropped endpoint is
    # replaced with one the server has never seen, and nothing else repairs it.
    it "re-subscribes on launch for a user who has reminders on" do
      configure_vapid
      user.update!(push_reminders_enabled: true)
      login_as(user)

      get account_path

      expect(response.body).to include("CodeGymPush.subscribeAndRegister()")
    end

    it "emits no push script for a logged-out visitor" do
      configure_vapid

      get login_path

      expect(response.body).not_to include("CodeGymPush")
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
