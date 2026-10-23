require "rails_helper"

RSpec.describe "Second-factor values in the log", type: :request do
  let(:user) { create_user_with_key(email: "dev@example.com") }
  let(:log) { StringIO.new }
  let(:capture) { ActiveSupport::Logger.new(log) }

  around do |example|
    Rails.logger.broadcast_to(capture)
    example.run
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  def code_fields(body, form_action)
    Nokogiri::HTML5(body).css("form[action='#{form_action}'] input[type=text]").map { |input| input["name"] }
  end

  def logged_parameters
    log.string.lines.grep(/Parameters:/).join
  end

  it "filters otp_code on the second sign-in step" do
    enroll_second_factor(user)
    post login_path, params: { email: user.email }
    post verify_login_code_path, params: { code: user.generate_login_code! }

    post second_factor_challenge_path, params: { otp_code: "123456" }

    expect(logged_parameters).to match(/"otp_code"\s*=>\s*"\[FILTERED\]"/)
    expect(log.string).not_to include("123456")
  end

  it "filters otp_code when turning the authenticator on" do
    login_as(user)

    post account_authenticator_path, params: { otp_code: "654321" }

    expect(logged_parameters).to match(/"otp_code"\s*=>\s*"\[FILTERED\]"/)
    expect(log.string).not_to include("654321")
  end

  it "logs neither the setup key nor the otpauth link when the setup page renders" do
    login_as(user)

    get account_authenticator_path

    secret = user.reload.otp_secret
    expect(response.body).to include(secret)
    expect(log.string).to include("AuthenticatorsController#show")
    expect(log.string).not_to include(secret)
    expect(log.string).not_to include("otpauth://")
  end

  it "filters the secret and the recovery digests from inspect" do
    enroll_second_factor(user)

    expect(user.reload.inspect).to include("otp_secret: [FILTERED]", "otp_backup_codes: [FILTERED]")
  end

  it "names every field that takes a second-factor code otp_code, so the :otp filter covers it" do
    login_as(user)
    get account_authenticator_path
    expect(code_fields(response.body, account_authenticator_path)).to eq([ "otp_code" ])

    secret, _codes = enroll_second_factor(user)
    post login_path, params: { email: user.email }
    post verify_login_code_path, params: { code: user.generate_login_code! }
    get second_factor_challenge_path
    expect(code_fields(response.body, second_factor_challenge_path)).to eq([ "otp_code" ])

    post second_factor_challenge_path, params: { otp_code: current_totp(secret) }
    get account_path
    expect(code_fields(response.body, account_authenticator_path)).to eq([ "otp_code" ])
    expect(code_fields(response.body, account_recovery_codes_path)).to eq([ "otp_code" ])
  end
end
