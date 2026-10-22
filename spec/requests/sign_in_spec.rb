require "rails_helper"

RSpec.describe "Signing in with a password and an authenticator code", type: :request do
  let(:password) { AuthHelpers::SPEC_PASSWORD }
  let(:user) { enroll_two_factor(create_user_with_key(email: "dev@example.com")) }

  def signed_in? = session["warden.user.user.key"].present?

  def sign_in_with(email: user.email, password: self.password, code: user.current_otp, **params)
    post user_session_path, params: { user: { email: email, password: password, otp_attempt: code }, **params }
  end

  describe "the login page" do
    before { get new_user_session_path }

    it "asks for an email, a password and an authenticator code" do
      fields = Nokogiri::HTML(response.body).css("input").map { |input| input["name"] }

      expect(fields).to include("user[email]", "user[password]", "user[otp_attempt]")
    end

    it "links to sign-up, password reset, confirmation and the first sign-in for older accounts" do
      expect(response.body).to include(new_user_registration_path, new_user_password_path,
                                       new_user_confirmation_path, first_sign_in_path)
    end

    it "offers no trial while trials are paused, and renders no app nav" do
      expect(response.body).not_to include(%(href="#{new_trial_path}"))
      expect(Nokogiri::HTML(response.body).at_css("nav")).to be_nil
    end
  end

  describe "POST /login" do
    it "signs in with the right password and the current code" do
      sign_in_with

      expect(response).to redirect_to(root_path)
      expect(signed_in?).to be(true)
    end

    it "refuses the right password without a code, with the same message as a wrong password" do
      sign_in_with(code: "")
      no_code_message = flash[:alert]
      sign_in_with(password: "wrong #{password}")

      expect(signed_in?).to be(false)
      expect(flash[:alert]).to eq(no_code_message).and eq("Incorrect email, password or code.")
    end

    it "refuses a wrong code" do
      sign_in_with(code: wrong_code_for(user.current_otp))

      expect(signed_in?).to be(false)
    end

    it "refuses a code that has already been used once" do
      code = user.current_otp
      sign_in_with(code: code)
      delete destroy_user_session_path

      sign_in_with(code: code)

      expect(signed_in?).to be(false)
    end

    it "accepts a backup code in place of the authenticator code, once" do
      backup_code = user.generate_otp_backup_codes!.first
      user.save!

      sign_in_with(code: backup_code)
      expect(signed_in?).to be(true)

      delete destroy_user_session_path
      sign_in_with(code: backup_code)
      expect(signed_in?).to be(false)
    end

    it "signs in an account with no authenticator yet on its password, then sends it to set one up" do
      unenrolled = User.create!(email: "new@example.com", name: "New", password: password)

      sign_in_with(email: unenrolled.email, code: "")
      follow_redirect!

      expect(response).to redirect_to(two_factor_setup_path)
    end

    it "refuses an account that signed up but has not confirmed its address" do
      registrant = User.new(email: "new@example.com", name: "New", password: password)
      registrant.signing_up = true
      registrant.save!

      sign_in_with(email: registrant.email, code: "")

      expect(signed_in?).to be(false)
      expect(flash[:alert]).to match(/confirm your email address/i)
    end

    it "sends the user back to the page they were bounced from" do
      get history_path
      expect(response).to redirect_to(new_user_session_path)

      sign_in_with

      expect(response).to redirect_to(history_path)
    end
  end

  describe "anonymized accounts" do
    it "end an open session on the next request" do
      login_as(user)
      get history_path
      expect(response).to have_http_status(:ok)

      user.anonymize!
      get history_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it "cannot sign in with the old address, password or code" do
      code = user.current_otp
      user.anonymize!

      sign_in_with(code: code)

      expect(signed_in?).to be(false)
    end
  end

  describe "DELETE /logout" do
    it "signs out and issues a new session" do
      sign_in_with
      get history_path
      before_sign_out = session.id.public_id

      delete destroy_user_session_path
      get new_user_session_path

      expect(signed_in?).to be(false)
      expect(session.id.public_id).not_to eq(before_sign_out)
    end
  end

  describe "a stale CSRF token", :with_csrf do
    def authenticity_token
      response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    end

    it "sends a logged-out visitor back to the login page with a friendly message instead of a raw 422" do
      sign_in_with(authenticity_token: "stale-bogus-token")

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq("Your session expired — please try again.")
    end

    # Signing in rotates the CSRF token, so a double-tapped login form must not tell a signed-in user the session expired.
    it "sends an already signed-in user home after a double-tapped login form" do
      get new_user_session_path
      token = authenticity_token
      sign_in_with(authenticity_token: token)

      sign_in_with(authenticity_token: token)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You are already signed in.")
    end

    it "never signs anyone in from a request whose token failed" do
      sign_in_with(authenticity_token: "stale-bogus-token")
      get history_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it "still warns on a stale logout instead of silently returning to the dashboard" do
      get new_user_session_path
      sign_in_with(authenticity_token: authenticity_token)

      delete destroy_user_session_path, params: { authenticity_token: "stale-bogus-token" }

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq("Your session expired — please try again.")
      expect(signed_in?).to be(true)
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
end
