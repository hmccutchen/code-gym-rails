require "rails_helper"

RSpec.describe "Moving the authenticator to a new phone", type: :request do
  let(:user) { enroll_two_factor(create_user_with_key) }

  before { login_as(user) }

  it "turns the authenticator off for a current code and shows a new QR code to scan" do
    old_secret = user.otp_secret

    post authenticator_move_path, params: { code: user.current_otp }
    follow_redirect!

    expect(response.body).to include("<svg")
    expect(user.reload.otp_secret).to be_present.and(satisfy { |secret| secret != old_secret })
    expect(user).not_to be_two_factor_enrolled
  end

  it "keeps the authenticator on for a wrong code" do
    post authenticator_move_path, params: { code: wrong_code_for(user.current_otp) }

    expect(response).to redirect_to(account_path)
    expect(user.reload).to be_two_factor_enrolled
  end

  it "offers the form on the Account page" do
    get account_path

    expect(response.body).to include(authenticator_move_path, "Move to a new phone")
  end
end
