require "rails_helper"

RSpec.describe "Resetting a forgotten password", type: :request do
  let(:user) { enroll_two_factor(create_user_with_key(email: "dev@example.com")) }
  let(:new_password) { "a different long password" }

  def reset_token
    ActionMailer::Base.deliveries.last.body.encoded[/reset_password_token=([^"&\s]+)/, 1]
  end

  def reset_password
    post user_password_path, params: { user: { email: user.email } }
    put user_password_path, params: { user: { reset_password_token: reset_token, password: new_password,
                                              password_confirmation: new_password } }
  end

  it "gives the same reply for an unknown address, so it reveals no accounts" do
    post user_password_path, params: { user: { email: "nobody@example.com" } }

    expect(response).to redirect_to(new_user_session_path)
    expect(flash[:notice]).to match(/If that address has an account/)
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "sets the new password without signing in" do
    reset_password

    expect(user.reload.valid_password?(new_password)).to be(true)
    expect(response).to redirect_to(new_user_session_path)
    expect(session["warden.user.user.key"]).to be_nil
  end

  it "still asks for the authenticator code after a reset" do
    reset_password

    post user_session_path, params: { user: { email: user.email, password: new_password } }
    expect(session["warden.user.user.key"]).to be_nil

    post user_session_path, params: { user: { email: user.email, password: new_password, otp_attempt: user.current_otp } }
    expect(session["warden.user.user.key"]).to be_present
  end
end
