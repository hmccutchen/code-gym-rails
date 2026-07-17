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
      expect(response).to redirect_to(root_path)

      # Token is single-use: a second visit must fail.
      get verify_auth_path(token: raw_token)
      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to match(/invalid or expired/i)
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

  describe "stale CSRF token (e.g. after a deploy restart)" do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it "redirects to login with a friendly flash instead of a raw 422" do
      post login_path, params: { email: "x@example.com", authenticity_token: "stale-bogus-token" }

      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to eq("Your session expired — please try again.")
    end
  end
end
