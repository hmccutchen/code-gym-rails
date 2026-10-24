require "rails_helper"

RSpec.describe "Push subscriptions", type: :request do
  let(:user) { create_user_with_key }

  def valid_params
    { endpoint: "https://fcm.googleapis.com/fcm/send/abc", p256dh: "p256", auth: "auth", enroll: true }
  end

  describe "POST /push_subscription" do
    it "records the endpoint and turns reminders on" do
      with_push_credentials do
        login_as(user)

        post push_subscription_path, params: valid_params

        expect(response).to have_http_status(:created)
        expect(user.reload.reminders_ready?).to be(true)
        expect(user.push_subscriptions.sole.endpoint).to eq("https://fcm.googleapis.com/fcm/send/abc")
      end
    end

    it "refuses a page-load registration after Turn off" do
      with_push_credentials do
        login_as(user)
        post push_subscription_path, params: valid_params
        delete push_subscription_path

        post push_subscription_path, params: valid_params.merge(enroll: false), as: :json

        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body).to include("status" => "error", "error" => I18n.t("accounts.push_reminders.registration_unavailable"))
        expect(user.reload.reminders_none?).to be(true)
        expect(user.push_subscriptions).to be_empty
      end
    end

    it "reloads intent when Turn off commits after registration loaded the user" do
      with_push_credentials do
        login_as(user)
        user.update!(reminder_level: :ready_and_nudges)
        allow(User).to receive(:signed_in_through).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { |loaded| loaded && User.where(id: loaded.id).update_all(reminder_level: User.reminder_levels[:none]) }
        end

        post push_subscription_path, params: valid_params.merge(enroll: false), as: :json

        expect(response).to have_http_status(:conflict)
        expect(user.reload.reminders_none?).to be(true)
        expect(user.push_subscriptions).to be_empty
      end
    end

    [ nil, "unexpected", false ].each do |enroll|
      it "does not treat #{enroll.inspect} as explicit enrollment" do
        with_push_credentials do
          login_as(user)
          params = valid_params.except(:enroll)
          params[:enroll] = enroll unless enroll.nil?

          post push_subscription_path, params: params, as: :json

          expect(response).to have_http_status(:conflict)
          expect(user.reload.reminders_none?).to be(true)
          expect(user.push_subscriptions).to be_empty
        end
      end
    end

    it "allows an explicit Turn on after Turn off" do
      with_push_credentials do
        login_as(user)
        post push_subscription_path, params: valid_params
        delete push_subscription_path

        post push_subscription_path, params: valid_params, as: :json

        expect(response).to have_http_status(:created)
        expect(user.reload.reminders_ready?).to be(true)
        expect(user.push_subscriptions.count).to eq(1)
      end
    end

    it "preserves nudges enabled after the request loaded its user" do
      with_push_credentials do
        login_as(user)
        allow(User).to receive(:signed_in_through).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { |loaded| loaded && User.where(id: loaded.id).update_all(reminder_level: User.reminder_levels[:ready_and_nudges]) }
        end

        post push_subscription_path, params: valid_params, as: :json

        expect(response).to have_http_status(:created)
        expect(user.reload.reminders_ready_and_nudges?).to be(true)
      end
    end

    # Held at the boundary so PushDelivery can assume an endpoint it can sign for.
    [
      [ "a non-https endpoint", { endpoint: "http://fcm.googleapis.com/fcm/send/abc" } ],
      [ "a missing endpoint",   { endpoint: "" } ],
      [ "a missing p256dh key", { p256dh: "" } ],
      [ "a missing auth key",   { auth: "" } ]
    ].each do |description, override|
      it "rejects #{description}" do
        with_push_credentials do
          login_as(user)

          post push_subscription_path, params: valid_params.merge(override)

          expect(response).to have_http_status(:unprocessable_content)
          expect(user.reload.reminders_none?).to be(true)
        end
      end
    end

    # Postgres varchar is unlimited and 2048 bytes fits under the unique index's btree limit; drive both.
    it "stores an endpoint at the full permitted length" do
      with_push_credentials do
        login_as(user)
        prefix   = "https://fcm.googleapis.com/fcm/send/"
        endpoint = prefix + ("a" * (PushSubscriptionsController::MAX_ENDPOINT_LENGTH - prefix.length))
        expect(endpoint.length).to eq(PushSubscriptionsController::MAX_ENDPOINT_LENGTH)

        post push_subscription_path, params: valid_params.merge(endpoint: endpoint)

        expect(response).to have_http_status(:created)
        expect(user.push_subscriptions.sole.endpoint).to eq(endpoint)
      end
    end

    it "rejects an endpoint longer than the column can be trusted to hold" do
      with_push_credentials do
        login_as(user)

        post push_subscription_path, params: valid_params.merge(endpoint: "https://fcm.googleapis.com/#{'a' * 3000}")

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    [
      [ "an internal host",        "https://10.0.0.5/hook" ],
      [ "localhost",               "https://localhost:5432/hook" ],
      [ "cloud metadata",          "https://169.254.169.254/latest/meta-data/" ],
      [ "an attacker's domain",    "https://evil.example.com/collect" ],
      [ "a lookalike suffix",      "https://fcm.googleapis.com.evil.example/collect" ]
    ].each do |description, endpoint|
      it "refuses an endpoint on #{description}" do
        with_push_credentials do
          login_as(user)

          post push_subscription_path, params: valid_params.merge(endpoint: endpoint)

          expect(response).to have_http_status(:unprocessable_content)
          expect(user.reload.reminders_none?).to be(true)
          expect(PushSubscription.count).to eq(0)
        end
      end
    end

    [
      "https://fcm.googleapis.com/fcm/send/abc",
      "https://updates.push.services.mozilla.com/wpush/v2/abc",
      "https://web.push.apple.com/abc",
      "https://par02p.notify.windows.com/w/?token=abc"
    ].each do |endpoint|
      it "accepts a real push service endpoint (#{URI.parse(endpoint).host})" do
        with_push_credentials do
          login_as(user)

          post push_subscription_path, params: valid_params.merge(endpoint: endpoint)

          expect(response).to have_http_status(:created)
          expect(user.push_subscriptions.sole.endpoint).to eq(endpoint)
        end
      end
    end

    it "refuses when no VAPID keypair is configured" do
      without_push_credentials do
        login_as(user)

        post push_subscription_path, params: valid_params

        expect(response).to have_http_status(:not_found)
        expect(user.reload.reminders_none?).to be(true)
      end
    end

    it "requires a logged-in user" do
      with_push_credentials do
        post push_subscription_path, params: valid_params

        expect(response).to redirect_to(login_path)
      end
    end

    it "does not walk a nudges user back to ready when their browser re-enrols" do
      with_push_credentials do
        login_as(user)
        user.update!(reminder_level: :ready_and_nudges)

        post push_subscription_path, params: {
          endpoint: "https://fcm.googleapis.com/fcm/send/abc", p256dh: "p", auth: "a"
        }

        expect(user.reload.reminders_ready_and_nudges?).to be(true)
      end
    end
  end

  describe "PATCH /push_subscription" do
    before { user.update!(reminder_level: :ready) }

    it "opts an enrolled user into nudges" do
      with_push_credentials do
        login_as(user)

        patch push_subscription_path, params: { nudges: "1" }

        expect(response).to redirect_to(account_path)
        expect(flash[:notice]).to eq(I18n.t("flash.push_subscriptions.settings_saved"))
        expect(user.reload.reminders_ready_and_nudges?).to be(true)
      end
    end

    it "opts them back out without un-enrolling them" do
      with_push_credentials do
        login_as(user)
        user.update!(reminder_level: :ready_and_nudges)

        patch push_subscription_path, params: { nudges: "0" }
        expect(user.reload.reminders_ready?).to be(true)
      end
    end

    # iOS grants permission only inside a click handler, so this form post must never enrol from nothing.
    it "cannot enrol a user who has never turned reminders on" do
      with_push_credentials do
        login_as(user)
        user.update!(reminder_level: :none)

        patch push_subscription_path, params: { nudges: "1" }

        expect(response).to redirect_to(account_path)
        expect(flash[:notice]).not_to eq(I18n.t("flash.push_subscriptions.settings_saved"))
        expect(user.reload.reminders_none?).to be(true)
      end
    end

    it "refuses when no VAPID keypair is configured" do
      without_push_credentials do
        login_as(user)

        patch push_subscription_path, params: { nudges: "1" }

        expect(response).to have_http_status(:not_found)
      end
    end

    it "turns nudges on from the switch and answers JSON" do
      with_push_credentials do
        login_as(user)

        patch push_subscription_path, params: { nudges: true }, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("nudges" => true)
        expect(user.reload.reminders_ready_and_nudges?).to be(true)
      end
    end

    it "turns nudges off from the switch" do
      with_push_credentials do
        login_as(user)
        user.update!(reminder_level: :ready_and_nudges)

        patch push_subscription_path, params: { nudges: false }, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("nudges" => false)
        expect(user.reload.reminders_ready?).to be(true)
      end
    end

    it "does not turn reminders back on when Turn off commits after the request loaded the user" do
      with_push_credentials do
        login_as(user)
        allow(User).to receive(:signed_in_through).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { |loaded| loaded && User.where(id: loaded.id).update_all(reminder_level: User.reminder_levels[:none]) }
        end

        patch push_subscription_path, params: { nudges: true }, as: :json

        expect(response).to have_http_status(:conflict)
        expect(user.reload.reminders_none?).to be(true)
      end
    end

    it "answers 409 to the switch when reminders are off, changing nothing" do
      with_push_credentials do
        login_as(user)
        user.update!(reminder_level: :none)

        patch push_subscription_path, params: { nudges: true }, as: :json

        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body).to include("status" => "error", "error" => I18n.t("accounts.push_reminders.nudges_unavailable"))
        expect(user.reload.reminders_none?).to be(true)
      end
    end

    it "answers 404 to the switch when no VAPID keypair is configured" do
      without_push_credentials do
        login_as(user)

        patch push_subscription_path, params: { nudges: true }, as: :json

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "registration and Turn off" do
    it "locks the user before registering or removing endpoints" do
      with_push_credentials do
        login_as(user)
        statements = []
        record = ->(*, payload) { statements << payload[:sql] }

        ActiveSupport::Notifications.subscribed(record, "sql.active_record") do
          post push_subscription_path, params: valid_params
          delete push_subscription_path
        end

        writes = statements.select { |sql| sql.match?(/FOR UPDATE|INSERT INTO "push_subscriptions"|DELETE FROM "push_subscriptions"/) }
        expect(writes.size).to eq(4)
        expect(writes[0]).to match(/FROM "users".*FOR UPDATE/)
        expect(writes[1]).to include('INSERT INTO "push_subscriptions"')
        expect(writes[2]).to match(/FROM "users".*FOR UPDATE/)
        expect(writes[3]).to include('DELETE FROM "push_subscriptions"')
        expect(user.reload.reminders_none?).to be(true)
        expect(user.push_subscriptions).to be_empty
      end
    end
  end

  describe "DELETE /push_subscription" do
    # Rows left behind would keep the job pushing to a browser whose owner asked it to stop.
    it "drops the endpoints as well as the intent" do
      with_push_credentials do
        login_as(user)
        post push_subscription_path, params: valid_params

        delete push_subscription_path

        expect(response).to redirect_to(account_path)
        expect(user.reload.reminders_none?).to be(true)
        expect(user.push_subscriptions).to be_empty
      end
    end
  end

  describe "the Account page control" do
    it "offers the toggle where a keypair is configured" do
      with_push_credentials do
        login_as(user)

        get account_path

        expect(response.body).to include("Turn on daily reminders")
      end
    end

    it "says nothing about reminders where none is configured" do
      without_push_credentials do
        login_as(user)

        get account_path

        expect(response.body).not_to include("Turn on daily reminders")
      end
    end

    it "embeds the VAPID public key rather than leaving the click to fetch it" do
      with_push_credentials do
        login_as(user)

        get account_path

        expect(response.body).to include(%(data-push-enable-vapid-key-value="#{PushCredentials::PUBLIC_KEY}"))
      end
    end

    it "renders the enable button disabled until its controller connects" do
      with_push_credentials do
        login_as(user)

        get account_path

        expect(Nokogiri::HTML(response.body).at_css("#push-enable")["disabled"]).not_to be_nil
      end
    end

    # fetch resolves for a 4xx and follows a logged-out redirect to a 200, so both must count as failure.
    it "treats a rejected or redirected enrolment as a failure, not a success" do
      with_push_credentials do
        login_as(user)

        get account_path

        expect(response.body).to include(%(data-push-enable-register-path-value="#{push_subscription_path}"))
        expect(response.body).to include(%(data-push-enable-register-failed-text-value="#{ERB::Util.html_escape(I18n.t("push.register_failed"))}"))
        source = Rails.root.join("app/javascript/code_gym/push.js").read
        expect(source).to include('send("POST", registerPath, {')
        expect(source).to include("if (!result.ok) throw failure(result.message)")
      end
    end

    it "re-subscribes on launch for an enrolled user, since the chain reaches a deferred module" do
      with_push_credentials do
        user.update!(reminder_level: :ready)
        login_as(user)

        get account_path

        expect(response.body).to include(%(data-controller="push-launch"))
        expect(response.body).to include(%(data-push-launch-register-path-value="#{push_subscription_path}"))
      end
    end

    it "mounts no push controller for a logged-out visitor" do
      with_push_credentials do
        get login_path

        expect(response.body).not_to include("push-launch")
        expect(response.body).not_to include("push-enable")
      end
    end

    it "renders the nudge opt-in on the Account page once enrolled" do
      with_push_credentials do
        login_as(user)
        user.update!(reminder_level: :ready)

        get account_path

        expect(response.body).to include("Also remind me during the day")
      end
    end
  end

  describe "GET /service-worker.js" do
    it "serves the worker from the root scope, without a session" do
      get "/service-worker.js"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("addEventListener(\"push\"")
    end

    it "versions the notification icon by its bytes, since production caches public files for a year" do
      get "/service-worker.js"

      icon = Object.new.extend(PublicFileHelper).versioned_public_path("icon-192.png")
      expect(response.body).to include(%(icon: "#{icon}"), %(badge: "#{icon}"))
      expect(response.body).not_to include('"/icon-192.png"')
    end
  end
end
