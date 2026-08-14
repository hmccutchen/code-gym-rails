require "rails_helper"

RSpec.describe "Sessions", type: :request do
  describe "POST /login" do
    # Regression guard: this drives User#generate_login_token! (BCrypt) under
    # bundler, which 500'd in production when the bcrypt gem was missing from
    # the Gemfile.
    it "creates a first-time user and enqueues the magic link email" do
      expect {
        post login_path, params: { email: "new@example.com", name: "New Dev" }
      }.to change(User, :count).by(1)
        .and have_enqueued_mail(UserMailer, :magic_link)

      expect(response).to redirect_to(login_path)
      expect(flash[:notice]).to match(/check your email/i)
    end

    it "reuses the existing user for a known email" do
      user = User.create!(email: "known@example.com", name: "Known")

      expect {
        post login_path, params: { email: "KNOWN@example.com" }
      }.not_to change(User, :count)

      expect(user.reload.login_token_digest).to be_present
    end

    it "rejects an invalid email without creating a user" do
      expect {
        post login_path, params: { email: "not-an-email" }
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /auth/verify" do
    let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

    it "logs the user in with a valid token and consumes it" do
      raw_token = user.generate_login_token!

      get verify_auth_path(token: raw_token)
      expect(response).to have_http_status(:ok)
      expect(session[:user_id]).to eq(user.id)

      # Token is single-use: a second visit must fail.
      get verify_auth_path(token: raw_token)
      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to match(/invalid or expired/i)
    end

    # Terminal by design: the tab that requested the link is polling and will
    # move itself to the dashboard, so redirecting here would run the app in
    # two tabs at once.
    it "renders a confirmation instead of redirecting into the app" do
      get verify_auth_path(token: user.generate_login_token!)

      expect(response).not_to have_http_status(:redirect)
      expect(response.body).to include("close this tab")
      expect(response.body).not_to include("<nav>")
    end

    # The only way forward for someone with no polling tab — a link opened on
    # a different device, or from a phone's mail app.
    it "offers a continue link for anyone with no tab to return to" do
      get verify_auth_path(token: user.generate_login_token!)

      expect(response.body).to include(%(href="#{root_path}"))
    end

    it "sends the continue link to the pre-login destination when there is one" do
      get history_path
      expect(session[:return_to]).to eq(history_path)

      get verify_auth_path(token: user.generate_login_token!)

      expect(response.body).to include(%(href="#{history_path}"))
    end

    # Flash rides the same cookie every tab shares, so a notice set here would
    # surface in the polling tab when it lands on the dashboard.
    it "sets no flash that could leak into the polling tab" do
      get verify_auth_path(token: user.generate_login_token!)

      expect(flash[:notice]).to be_nil
    end

    it "rejects an expired token" do
      raw_token = user.generate_login_token!

      travel(User::TOKEN_EXPIRY + 1.minute) do
        get verify_auth_path(token: raw_token)
        expect(response).to redirect_to(login_path)
        expect(flash[:alert]).to match(/invalid or expired/i)
      end
    end

    it "rejects a garbage token" do
      get verify_auth_path(token: "garbage")
      expect(response).to redirect_to(login_path)
    end
  end

  describe "stale CSRF token (e.g. after a deploy restart)", :with_csrf do
    it "redirects to login with a friendly flash instead of a raw 422" do
      post login_path, params: { email: "x@example.com", authenticity_token: "stale-bogus-token" }

      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to eq("Your session expired — please try again.")
    end
  end

  describe "POST /login/code" do
    include ActiveJob::TestHelper

    # The generated code is random, so a hardcoded "wrong" code can occasionally
    # be the real one. Derive one that never collides.
    def wrong_code_for(code)
      format("%06d", (code.to_i + 1) % 1_000_000)
    end

    it "logs the user in with the code emailed after POST /login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end

      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/enter this code: (\d{6})/, 1]
      expect(raw_code).to be_present

      post verify_login_code_path, params: { code: raw_code }

      expect(response).to redirect_to(root_path)
      expect(session[:user_id]).to be_present
    end

    it "rejects an incorrect code without logging in" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/enter this code: (\d{6})/, 1]
      expect(raw_code).to be_present

      post verify_login_code_path, params: { code: wrong_code_for(raw_code) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(session[:user_id]).to be_nil
    end

    it "locks out after 5 wrong attempts, invalidating the emailed link too" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end
      body = ActionMailer::Base.deliveries.last.body.encoded
      raw_token = body[/token=([\w-]+)/, 1]
      raw_code  = body[/enter this code: (\d{6})/, 1]
      expect(raw_token).to be_present
      expect(raw_code).to be_present
      wrong = wrong_code_for(raw_code)

      5.times { post verify_login_code_path, params: { code: wrong } }

      get verify_auth_path(token: raw_token)
      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to match(/invalid or expired/i)
    end

    it "returns nil-equivalent (no session) when there is no pending login in this browser" do
      post verify_login_code_path, params: { code: "123456" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(session[:user_id]).to be_nil
    end
  end

  describe "login code gating by device" do
    include ActiveJob::TestHelper

    it "emails a login code when the request came from a touch device" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end

      expect(ActionMailer::Base.deliveries.last.body.encoded).to match(/enter this code: \d{6}/)
    end

    it "omits the login code when the request came from a desktop browser" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end

      expect(ActionMailer::Base.deliveries.last.body.encoded).not_to include("enter this code")
    end

    it "still emails a working magic link to a desktop browser" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end
      raw_token = ActionMailer::Base.deliveries.last.body.encoded[/token=([\w-]+)/, 1]

      get verify_auth_path(token: raw_token)

      expect(response).to have_http_status(:ok)
      expect(session[:user_id]).to be_present
    end

    it "clears the pending-login device flag after a link login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end
      raw_token = ActionMailer::Base.deliveries.last.body.encoded[/token=([\w-]+)/, 1]

      get verify_auth_path(token: raw_token)

      expect(session[:pending_login_email]).to be_nil
      expect(session[:pending_login_touch]).to be_nil
    end

    it "clears the pending-login device flag after a code login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/enter this code: (\d{6})/, 1]

      post verify_login_code_path, params: { code: raw_code }

      expect(session[:pending_login_email]).to be_nil
      expect(session[:pending_login_touch]).to be_nil
    end
  end

  describe "the login page's device-gated code UI" do
    it "carries a touch_device field for the client script to set" do
      get login_path

      expect(response.body).to include('name="touch_device"')
    end

    it "offers the code form on the pending page after a touch-device request" do
      post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }

      get login_path

      expect(response.body).to include("/login/code")
      expect(response.body).to include("6-digit code")
    end

    it "hides the code form on the pending page after a desktop request" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }

      get login_path

      expect(response.body).not_to include("/login/code")
      expect(response.body).to include("Check your email")
    end
  end

  describe "GET /login/status" do
    it "reports unauthenticated before verification" do
      get login_status_path
      expect(JSON.parse(response.body)).to eq("authenticated" => false)
    end

    it "reports authenticated once verify has completed in this session" do
      user = User.create!(email: "dev@example.com", name: "Dev")
      raw_token = user.generate_login_token!

      get login_status_path
      expect(JSON.parse(response.body)["authenticated"]).to eq(false)

      get verify_auth_path(token: raw_token)

      get login_status_path
      expect(JSON.parse(response.body)["authenticated"]).to eq(true)
    end
  end

  describe "session rotation on login" do
    include ActiveJob::TestHelper

    it "issues a new session on link login so nothing written before auth survives" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end
      raw_token = ActionMailer::Base.deliveries.last.body.encoded[/token=([\w-]+)/, 1]
      pre_login_session_id = session.id.public_id

      get verify_auth_path(token: raw_token)

      expect(session[:user_id]).to be_present
      expect(session.id.public_id).not_to eq(pre_login_session_id)
    end

    it "issues a new session on code login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/enter this code: (\d{6})/, 1]
      pre_login_session_id = session.id.public_id

      post verify_login_code_path, params: { code: raw_code }

      expect(session[:user_id]).to be_present
      expect(session.id.public_id).not_to eq(pre_login_session_id)
    end

    it "issues a new session on logout" do
      user = create_user_with_key(email: "dev@example.com")
      login_as(user)
      get history_path
      pre_logout_session_id = session.id.public_id

      delete logout_path

      expect(session[:user_id]).to be_nil
      expect(session.id.public_id).not_to eq(pre_logout_session_id)
    end

    # The rotation discards the whole session, so return_to has to be read out
    # before reset_session or the verify page's continue link silently loses it.
    it "still points the user at the page they were bounced from" do
      user = User.create!(email: "dev@example.com", name: "Dev")
      raw_token = user.generate_login_token!

      get history_path
      expect(response).to redirect_to(login_path)

      get verify_auth_path(token: raw_token)

      expect(response.body).to include(%(href="#{history_path}"))
    end

    it "clears the pending-login state on code login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/enter this code: (\d{6})/, 1]

      post verify_login_code_path, params: { code: raw_code }

      expect(session[:pending_login_email]).to be_nil
      expect(session[:pending_login_touch]).to be_nil
    end
  end

  describe "stale CSRF token after the session rotates", :with_csrf do
    include ActiveJob::TestHelper

    def authenticity_token
      response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    end

    # Logging in rotates the session, and the CSRF token with it, so the code
    # form — rendered under the pre-login session — is stale the moment it
    # succeeds. Re-submitting it (a double-tap on mobile) must not tell an
    # already-logged-in user their session expired.
    it "sends an already-logged-in user home instead of claiming the session expired" do
      get login_path
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev", touch_device: "1",
                                   authenticity_token: authenticity_token }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/enter this code: (\d{6})/, 1]

      get login_path
      code_form_token = authenticity_token

      post verify_login_code_path, params: { code: raw_code, authenticity_token: code_form_token }
      expect(response).to redirect_to(root_path)

      post verify_login_code_path, params: { code: raw_code, authenticity_token: code_form_token }

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to be_nil
      expect(session[:user_id]).to be_present
    end

    it "still warns a logged-out user whose token is stale" do
      post login_path, params: { email: "x@example.com", authenticity_token: "stale-bogus-token" }

      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to eq("Your session expired — please try again.")
    end

    # Logout is a sessions action too, but silently returning someone to the
    # dashboard when they asked to sign out would hide a failure they care
    # about — and leave them still logged in with nothing said.
    it "still warns on a stale logout instead of silently returning to the dashboard" do
      user = create_user_with_key(email: "out@example.com")
      login_as(user)

      delete logout_path, params: { authenticity_token: "stale-bogus-token" }

      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to eq("Your session expired — please try again.")
      expect(session[:user_id]).to be_present
    end
  end

  describe "session lifetime" do
    it "expires the session cookie after 2 days" do
      expect(Rails.application.config.session_options[:expire_after]).to eq(2.days)
    end

    it "keeps the default cookie key so existing sessions survive the change" do
      expect(Rails.application.config.session_options[:key]).to eq("_code_gym_rails_session")
    end
  end

  describe "anonymized users" do
    it "rejects a session cookie belonging to an anonymized user" do
      user = create_user_with_key(email: "gone@example.com")
      login_as(user)
      get history_path
      expect(response).to have_http_status(:ok)

      user.anonymize!

      get history_path
      expect(response).to redirect_to(login_path)
    end

    it "creates a brand-new user when the original email is used again" do
      user = create_user_with_key(email: "gone@example.com")
      user.anonymize!

      expect {
        post login_path, params: { email: "gone@example.com", name: "Gone" }
      }.to change(User, :count).by(1)

      new_user = User.find_by(email: "gone@example.com")
      expect(new_user.id).not_to eq(user.id)
      expect(new_user.daily_exercises).to be_empty
      expect(new_user.api_key).to be_nil
    end

    it "refuses a magic-link token issued before deletion" do
      user = create_user_with_key(email: "gone@example.com")
      raw_token = user.generate_login_token!
      user.anonymize!

      get verify_auth_path(token: raw_token)

      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to match(/invalid or expired/i)
    end
  end
end
