require "rails_helper"

RSpec.describe "Recovery codes", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key(email: "dev@example.com") }
  let!(:enrollment) { enroll_second_factor(user) }
  let(:secret) { enrollment.first }
  let(:old_codes) { enrollment.last }

  def sign_in_with_both_factors(browser = self, code: current_totp(secret))
    browser.post login_path, params: { email: user.email }
    browser.post verify_login_code_path, params: { code: user.generate_login_code! }
    browser.post second_factor_challenge_path, params: { otp_code: code }
  end

  def codes_on_page(body = response.body)
    Nokogiri::HTML5(body).css(".recovery-code-list li").map(&:text)
  end

  it "shows a new set once, without caching, and voids the old set" do
    sign_in_with_both_factors
    travel User::TOTP_INTERVAL.seconds

    post account_recovery_codes_path, params: { otp_code: current_totp(secret) }

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    new_codes = codes_on_page
    expect(new_codes.size).to eq(10)
    expect(new_codes & old_codes).to be_empty
    expect(user.reload.verify_second_factor!(old_codes.second).status).to eq(:rejected)
    expect(user.verify_second_factor!(new_codes.first).status).to eq(:recovery_code)
  end

  it "refuses the emailed code" do
    sign_in_with_both_factors
    emailed_code = user.generate_login_code!

    post account_recovery_codes_path, params: { otp_code: emailed_code }

    expect(response).to redirect_to(account_path)
    expect(flash[:alert]).to match(/didn't work/)
    expect(user.reload.otp_backup_codes.size).to eq(10)
  end

  it "leaves another signed-in session signed in" do
    other = open_session
    sign_in_with_both_factors(other, code: old_codes.first)
    sign_in_with_both_factors(code: old_codes.second)
    travel 1.second

    post account_recovery_codes_path, params: { otp_code: current_totp(secret) }
    expect(response).to have_http_status(:ok)

    other.get history_path
    expect(other.response).to have_http_status(:ok)
  end

  it "mails one notice with none of the codes in it" do
    sign_in_with_both_factors
    travel User::TOTP_INTERVAL.seconds

    perform_enqueued_jobs do
      post account_recovery_codes_path, params: { otp_code: current_totp(secret) }
    end

    notices = ActionMailer::Base.deliveries.select { |mail| mail.subject.include?("sign-in settings") }
    expect(notices.size).to eq(1)
    body = notices.first.body.encoded
    expect(body).to include("New recovery codes were made")
    codes_on_page.each { |code| expect(body).not_to include(code) }
  end

  it "shows the daily cap message once the cap is reached" do
    sign_in_with_both_factors
    user.update!(second_factor_failures: User::SECOND_FACTOR_DAILY_FAILURES, second_factor_failures_since: 1.hour.ago)
    travel User::TOTP_INTERVAL.seconds

    post account_recovery_codes_path, params: { otp_code: current_totp(secret) }

    expect(flash[:alert]).to match(/too many wrong authenticator codes/)
  end

  describe "rate limit" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "shares its count with turning the authenticator off" do
      sign_in_with_both_factors
      10.times { delete account_authenticator_path, params: { otp_code: "AAAAA-AAAAA" } }
      travel User::TOTP_INTERVAL.seconds

      post account_recovery_codes_path, params: { otp_code: current_totp(secret) }

      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to match(/too many attempts/i)
    end
  end
end
