require "rails_helper"

RSpec.describe "Sessions", type: :request do
  describe "POST /login" do
    # Regression guard: this drives User#generate_login_code! (BCrypt) under
    # bundler, which 500'd in production when the bcrypt gem was missing from
    # the Gemfile.
    it "creates a first-time user and enqueues the login code email" do
      expect {
        post login_path, params: { email: "new@example.com", name: "New Dev" }
      }.to change(User, :count).by(1)
        .and have_enqueued_mail(UserMailer, :login_code)

      expect(response).to redirect_to(login_path)
      expect(flash[:notice]).to match(/check your email/i)
    end

    # Every requester gets a code now, with no client-supplied hint deciding
    # who is worth mailing one to.
    it "mails a code regardless of any touch_device hint in the params" do
      expect {
        post login_path, params: { email: "new@example.com", touch_device: "" }
      }.to have_enqueued_mail(UserMailer, :login_code)
    end

    it "records the pending state without a device flag" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }

      expect(session[:pending_login_email]).to eq("dev@example.com")
      expect(session[:pending_login_at]).to be_present
      expect(session[:pending_login_touch]).to be_nil
    end

    it "reuses the existing user for a known email" do
      user = User.create!(email: "known@example.com", name: "Known")

      expect {
        post login_path, params: { email: "KNOWN@example.com" }
      }.not_to change(User, :count)

      expect(user.reload.login_code_digest).to be_present
    end

    it "rejects an invalid email without creating a user" do
      expect {
        post login_path, params: { email: "not-an-email" }
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "the login page" do
    it "marks the email field as required and the name field as not" do
      get login_path

      expect(response.body).to include("Work email *")
      expect(response.body).not_to include("Name *")
    end

    it "offers the code form as soon as a login is pending" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }

      get login_path

      expect(response.body).to include("/login/code")
      expect(response.body).to include("6-digit code")
    end

    # The page carries no JavaScript at all now: polling is gone with the
    # link it waited on, and the device sniffing went with the gating.
    it "carries no polling or device-detection script" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }

      get login_path

      expect(response.body).not_to include("matchMedia")
      expect(response.body).not_to include("navigator.standalone")
      expect(response.body).not_to include("login/status")
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

    it "logs the user in with the code emailed after POST /login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end

      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]
      expect(raw_code).to be_present

      post verify_login_code_path, params: { code: raw_code }

      expect(response).to redirect_to(root_path)
      expect(session[:user_id]).to be_present
    end

    it "rejects an incorrect code without logging in" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]
      expect(raw_code).to be_present

      post verify_login_code_path, params: { code: wrong_code_for(raw_code) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(session[:user_id]).to be_nil
    end

    it "locks out after 5 wrong attempts, invalidating the code" do
      user = User.create!(email: "dev@example.com", name: "Dev")
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]
      expect(raw_code).to be_present
      wrong = wrong_code_for(raw_code)

      5.times { post verify_login_code_path, params: { code: wrong } }

      expect(user.reload.login_code_digest).to be_nil
    end

    it "returns nil-equivalent (no session) when there is no pending login in this browser" do
      post verify_login_code_path, params: { code: "123456" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(session[:user_id]).to be_nil
    end
  end

  describe "session rotation on login" do
    include ActiveJob::TestHelper

    it "issues a new session on code login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]
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
    # before reset_session or a successful login silently loses it.
    it "still points the user at the page they were bounced from" do
      user = User.create!(email: "dev@example.com", name: "Dev")

      get history_path
      expect(response).to redirect_to(login_path)

      post login_path, params: { email: user.email }
      post verify_login_code_path, params: { code: user.generate_login_code! }

      expect(response).to redirect_to(history_path)
    end

    it "clears the pending-login state after a code login" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]

      post verify_login_code_path, params: { code: raw_code }

      expect(session[:pending_login_email]).to be_nil
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
        post login_path, params: { email: "dev@example.com", name: "Dev",
                                   authenticity_token: authenticity_token }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]

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

      # login_as posts with no authenticity_token at all, which real forgery
      # protection (on for this describe block) rejects outright — so getting
      # logged in here has to go through the same token-carrying flow as the
      # test above rather than the shared helper.
      get login_path
      perform_enqueued_jobs do
        post login_path, params: { email: user.email, authenticity_token: authenticity_token }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]

      get login_path
      post verify_login_code_path, params: { code: raw_code, authenticity_token: authenticity_token }

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

    it "refuses a code issued before deletion" do
      user = create_user_with_key(email: "gone@example.com")
      post login_path, params: { email: user.email }
      code = user.generate_login_code!
      user.anonymize!

      post verify_login_code_path, params: { code: code }

      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to match(/incorrect or expired/i)
    end
  end

  # A production lockout: the pending-login state used to replace the email
  # form rather than sit above it, so any way of reaching verify outside this
  # browser's cookie jar — a mail client's in-app browser, an expired or
  # already-consumed link — left the login page with no way to request a new
  # one. Clearing cookies was the only recovery.
  describe "recovering from a pending login that never completes" do
    include ActiveJob::TestHelper

    def email_form_present?
      response.body.include?('name="email"')
    end

    it "still offers the email form while a login is pending" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }

      get login_path

      expect(email_form_present?).to be(true)
    end

    # The code is bound to the session that requested it, so a second browser
    # holding the same address gets nowhere — and must still be able to ask
    # for its own code rather than being stranded.
    it "keeps the form reachable in a browser that did not request the code" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      user = User.find_by(email: "dev@example.com")
      code = user.generate_login_code!

      other_jar = open_session
      other_jar.post verify_login_code_path, params: { code: code }

      expect(other_jar.session[:user_id]).to be_nil
      expect(other_jar.response.body).to include('name="email"')
    end

    it "lets a new code be requested from the pending page" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      get login_path

      expect {
        post login_path, params: { email: "dev@example.com" }
      }.to have_enqueued_mail(UserMailer, :login_code)
    end

    it "drops the pending state once the code it describes has expired" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }

      travel(User::LOGIN_CODE_EXPIRY + 1.minute) do
        get login_path

        expect(response.body).not_to include("pending-message")
        expect(email_form_present?).to be(true)
      end
    end

    # The database is the enforcer here, not the session stamp:
    # User.authenticate_login_code already filters on login_code_sent_at
    # within LOGIN_CODE_EXPIRY, and both clocks start from the same #create. So
    # this guards the outcome rather than the mechanism — it would still pass
    # with pending_login_email's expiry removed from #verify_code, where that
    # check is redundancy behind one authority rather than the thing keeping
    # an expired code out.
    it "refuses a login code once the code's window has passed" do
      perform_enqueued_jobs do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
      end
      raw_code = ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]

      travel(User::LOGIN_CODE_EXPIRY + 1.minute) do
        post verify_login_code_path, params: { code: raw_code }
      end

      expect(session[:user_id]).to be_nil
    end
  end
end
