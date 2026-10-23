require "rails_helper"

RSpec.describe "Authenticator setup", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key(email: "dev@example.com") }

  def secret_on_page(browser = self)
    browser.response.body[/secret=([A-Z2-7]+)/, 1]
  end

  def setup_code(browser = self)
    current_totp(secret_on_page(browser))
  end

  def sign_in_with_both_factors(account, secret)
    post login_path, params: { email: account.email }
    post verify_login_code_path, params: { code: account.generate_login_code! }
    post second_factor_challenge_path, params: { otp_code: current_totp(secret) }
  end

  describe "GET /account/authenticator" do
    it "asks an old sign-in to sign in again" do
      login_as(user)

      travel User::RECENT_SIGN_IN + 1.second do
        get account_authenticator_path
      end

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sign in again first")
      expect(user.reload.otp_secret).to be_nil
    end

    it "brings the sign-in-again button back to the setup page" do
      login_as(user)
      delete sign_in_again_account_authenticator_path
      expect(response).to redirect_to(login_path)
      expect(session[:user_id]).to be_nil

      login_as(user)

      expect(response).to redirect_to(account_authenticator_path)
    end

    it "shows a link, a setup key and a QR code carrying the same secret" do
      login_as(user)

      get account_authenticator_path

      secret = secret_on_page
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("otpauth://totp/Coding%20Gym:dev%40example.com?secret=#{secret}")
      expect(response.body).to include(secret.scan(/.{1,4}/).join(" "))
      svg = Nokogiri::HTML5(response.body).at_css("svg.qr-code")
      expect(svg).to be_present
      expect(svg.to_html).to eq(Nokogiri::HTML5(helper_svg_for(user, secret)).at_css("svg.qr-code").to_html)
    end

    it "is never cached" do
      login_as(user)

      get account_authenticator_path

      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "sends a user whose authenticator is already on back to the Account page" do
      secret, _codes = enroll_second_factor(user)
      sign_in_with_both_factors(user, secret)

      get account_authenticator_path

      expect(response).to redirect_to(account_path)
    end

    def helper_svg_for(account, secret)
      ApplicationController.helpers.extend(AuthenticatorSetupsHelper).qr_code_svg(account.authenticator_uri(secret))
    end
  end

  describe "the setup key" do
    it "stays in this browser's session, off the account, until a right code turns the authenticator on" do
      login_as(user)
      get account_authenticator_path
      first_view = secret_on_page

      get account_authenticator_path

      expect(secret_on_page).to eq(first_view)
      expect(user.reload.otp_secret).to be_nil
    end

    it "differs between sessions, so a key read in another one is never the key the owner enrolls" do
      intruder = open_session
      owner = open_session
      [ intruder, owner ].each do |browser|
        browser.post login_path, params: { email: user.email }
        browser.post verify_login_code_path, params: { code: user.generate_login_code! }
        browser.get account_authenticator_path
      end
      intruder_key = secret_on_page(intruder)
      owner_key = secret_on_page(owner)
      expect(intruder_key).not_to eq(owner_key)

      owner.post account_authenticator_path, params: { otp_code: current_totp(owner_key) }

      expect(user.reload.two_factor_enabled?).to be(true)
      expect(user.otp_secret).to eq(owner_key)
      expect(user.otp_secret).not_to eq(intruder_key)
    end
  end

  describe "POST /account/authenticator" do
    it "turns it on and shows ten recovery codes once, without caching" do
      login_as(user)
      get account_authenticator_path

      post account_authenticator_path, params: { otp_code: setup_code }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      codes = Nokogiri::HTML(response.body).css(".recovery-code-list li").map(&:text)
      expect(codes.size).to eq(10)
      expect(user.reload.two_factor_enabled?).to be(true)

      post account_authenticator_path, params: { otp_code: "000000" }

      expect(response).to redirect_to(account_path)
      expect(response.body).not_to include(codes.first)
    end

    it "re-renders the setup page after a wrong code" do
      login_as(user)
      get account_authenticator_path
      right = setup_code

      post account_authenticator_path, params: { otp_code: right == "000000" ? "000001" : "000000" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(user.reload.two_factor_enabled?).to be(false)
    end

    it "refuses an old sign-in" do
      login_as(user)
      get account_authenticator_path

      travel User::RECENT_SIGN_IN + 1.second do
        post account_authenticator_path, params: { otp_code: setup_code }
      end

      expect(response).to have_http_status(:forbidden)
      expect(user.reload.two_factor_enabled?).to be(false)
    end
  end

  describe "DELETE /account/authenticator" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }

    it "turns it off with a current code" do
      sign_in_with_both_factors(user, secret)
      travel User::TOTP_INTERVAL.seconds

      delete account_authenticator_path, params: { otp_code: current_totp(secret) }

      expect(response).to redirect_to(account_path)
      expect(user.reload.two_factor_enabled?).to be(false)
    end

    it "turns it off with a recovery code" do
      sign_in_with_both_factors(user, secret)

      delete account_authenticator_path, params: { otp_code: enrollment.last.first }

      expect(user.reload.two_factor_enabled?).to be(false)
    end

    it "refuses the emailed code" do
      sign_in_with_both_factors(user, secret)
      emailed_code = user.generate_login_code!

      delete account_authenticator_path, params: { otp_code: emailed_code }

      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to match(/didn't work/)
      expect(user.reload.two_factor_enabled?).to be(true)
    end

    it "shows the daily cap message once the cap is reached" do
      sign_in_with_both_factors(user, secret)
      user.update!(second_factor_failures: User::SECOND_FACTOR_DAILY_FAILURES, second_factor_failures_since: 1.hour.ago)
      travel User::TOTP_INTERVAL.seconds

      delete account_authenticator_path, params: { otp_code: current_totp(secret) }

      expect(flash[:alert]).to match(/too many wrong authenticator codes/)
      expect(user.reload.two_factor_enabled?).to be(true)
    end
  end

  describe "ending other sessions" do
    it "signs out every other session when the authenticator is turned on, and keeps this one" do
      a = open_session
      b = open_session
      [ a, b ].each do |browser|
        browser.post login_path, params: { email: user.email }
        browser.post verify_login_code_path, params: { code: user.generate_login_code! }
      end
      travel 1.second

      a.get account_authenticator_path
      a.post account_authenticator_path, params: { otp_code: setup_code(a) }
      expect(user.reload.two_factor_enabled?).to be(true)

      b.get history_path
      expect(b.response.location).to eq(login_url)
      expect(User.signed_in_through(user_id: b.session[:user_id], signed_in_at: b.session[:signed_in_at])).to be_nil
      a.get history_path
      expect(a.response).to have_http_status(:ok)
    end

    it "signs out every other session when the authenticator is turned off" do
      secret, codes = enroll_second_factor(user)
      a = open_session
      b = open_session
      [ a, b ].each_with_index do |browser, index|
        browser.post login_path, params: { email: user.email }
        browser.post verify_login_code_path, params: { code: user.generate_login_code! }
        browser.post second_factor_challenge_path, params: { otp_code: codes[index] }
      end
      travel 1.second

      a.delete account_authenticator_path, params: { otp_code: current_totp(secret) }
      expect(user.reload.two_factor_enabled?).to be(false)

      b.get history_path
      expect(b.response.location).to eq(login_url)
      a.get history_path
      expect(a.response).to have_http_status(:ok)
    end
  end

  describe "notices" do
    it "mails one notice when the authenticator is turned on, with neither the key nor a code" do
      login_as(user)
      get account_authenticator_path
      secret = secret_on_page

      perform_enqueued_jobs do
        post account_authenticator_path, params: { otp_code: setup_code }
      end

      notices = ActionMailer::Base.deliveries.select { |mail| mail.subject.include?("sign-in settings") }
      expect(notices.size).to eq(1)
      body = notices.first.body.encoded
      expect(body).to include("An authenticator app was turned on")
      expect(body).not_to include(secret)
      codes = Nokogiri::HTML(response.body).css(".recovery-code-list li").map(&:text)
      codes.each { |code| expect(body).not_to include(code) }
    end

    it "mails one notice when the authenticator is turned off" do
      secret, _codes = enroll_second_factor(user)
      sign_in_with_both_factors(user, secret)
      travel User::TOTP_INTERVAL.seconds
      code = current_totp(secret)

      perform_enqueued_jobs do
        delete account_authenticator_path, params: { otp_code: code }
      end

      notices = ActionMailer::Base.deliveries.select { |mail| mail.subject.include?("sign-in settings") }
      expect(notices.size).to eq(1)
      expect(notices.first.body.encoded).to include("turned off")
      expect(notices.first.body.encoded).not_to include(code)
    end
  end

  describe "rate limit" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "counts turning on, turning off and making new codes together" do
      secret, _codes = enroll_second_factor(user)
      sign_in_with_both_factors(user, secret)
      5.times { delete account_authenticator_path, params: { otp_code: "AAAAA-AAAAA" } }
      5.times { post account_recovery_codes_path, params: { otp_code: "AAAAA-AAAAA" } }
      travel User::TOTP_INTERVAL.seconds

      delete account_authenticator_path, params: { otp_code: current_totp(secret) }

      expect(flash[:alert]).to match(/too many attempts/i)
      expect(user.reload.two_factor_enabled?).to be(true)
    end
  end
end
