require "rails_helper"

RSpec.describe "Sessions ended by sessions_valid_after", type: :request do
  let(:user) { create_user_with_key(email: "dev@example.com") }

  it "keeps a session signed in after the cutoff" do
    user.update!(sessions_valid_after: 1.minute.ago)
    login_as(user)

    get history_path

    expect(response).to have_http_status(:ok)
  end

  it "sends a session signed in before the cutoff back to the login page" do
    login_as(user)
    user.update!(sessions_valid_after: 1.second.from_now)

    get history_path

    expect(response).to redirect_to(login_path)
  end

  it "sends a session with no sign-in stamp, as every session from before the stamp has, back to the login page" do
    allow(User).to receive(:session_stamp).and_return(nil)
    login_as(user)
    allow(User).to receive(:session_stamp).and_call_original

    get history_path

    expect(response).to redirect_to(login_path)
  end

  it "ends an email-only sign-in when the authenticator is turned on while that code is being checked" do
    allow(User).to receive(:authenticate_login_code).and_wrap_original do |original, **args|
      original.call(**args).tap { enroll_second_factor(User.find(user.id)) }
    end
    post login_path, params: { email: user.email }
    post verify_login_code_path, params: { code: user.generate_login_code! }
    expect(session[:user_id]).to eq(user.id)

    get history_path

    expect(response).to redirect_to(login_path)
  end

  it "ends a two-factor sign-in when the authenticator is turned off while that code is being checked" do
    secret, codes = enroll_second_factor(user)
    allow_any_instance_of(User).to receive(:answer_second_factor_challenge!).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap { User.find(user.id).disable_second_factor!(codes.last) }
    end
    post login_path, params: { email: user.email }
    post verify_login_code_path, params: { code: user.generate_login_code! }
    post second_factor_challenge_path, params: { otp_code: current_totp(secret) }
    expect(session[:user_id]).to eq(user.id)

    get history_path

    expect(response).to redirect_to(login_path)
  end
end
