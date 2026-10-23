require "rails_helper"

# Each of these posts spends something, so a second tap must not post it again (loading_form_controller.md).
RSpec.describe "Submit guards on the sign-in and authenticator forms", type: :request do
  let(:user) { create_fake_provider_user }

  def guarded_form?(action)
    Nokogiri::HTML(response.body).css(%(form[action="#{action}"])).any? do |form|
      form["data-controller"] == "loading-form" && form["data-action"].to_s.include?("submit->loading-form#submit")
    end
  end

  it "guards Send code" do
    get login_path

    expect(guarded_form?(login_path)).to be(true)
  end

  it "guards Verify code" do
    post login_path, params: { email: user.email }
    follow_redirect!

    expect(guarded_form?(verify_login_code_path)).to be(true)
  end

  it "guards the trial form" do
    stub_env("HOUSE_OPENAI_API_KEY" => "sk-house")
    get new_trial_path

    expect(guarded_form?(start_trial_path)).to be(true)
  end

  it "guards Turn on" do
    login_as(user)
    get account_authenticator_path

    expect(guarded_form?(account_authenticator_path)).to be(true)
  end

  context "with the authenticator on" do
    let!(:secret) { enroll_second_factor(user).first }

    it "guards the second step" do
      login_as(user)
      get second_factor_challenge_path

      expect(guarded_form?(second_factor_challenge_path)).to be(true)
    end

    it "guards Turn off and new recovery codes" do
      login_as(user)
      post second_factor_challenge_path, params: { otp_code: current_totp(secret) }
      get account_path

      expect(guarded_form?(account_authenticator_path)).to be(true)
      expect(guarded_form?(account_recovery_codes_path)).to be(true)
    end
  end
end
