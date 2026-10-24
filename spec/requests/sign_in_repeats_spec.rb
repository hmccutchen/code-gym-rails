require "rails_helper"

RSpec.describe "A repeated sign-in post", type: :request do
  let(:user) { create_user_with_key(email: "dev@example.com") }
  let(:session_cookie) { "_code_gym_rails_session" }

  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  # A double tap sends both posts with the cookie from before the first one answered.
  def post_twice(path, params)
    cookie_before = cookies[session_cookie]
    post path, params: params
    first = response
    cookies[session_cookie] = cookie_before
    post path, params: params
    first
  end

  def request_code
    post login_path, params: { email: user.email }
    user.generate_login_code!
  end

  it "signs in on the second post of an emailed code the first post just redeemed" do
    code = request_code

    first = post_twice(verify_login_code_path, { code: code })

    expect(first).to redirect_to(root_path)
    expect(response).to redirect_to(root_path)
    expect(session[:user_id]).to eq(user.id)
  end

  it "refuses the repeat once the window has passed" do
    code = request_code
    cookie_before = cookies[session_cookie]
    post verify_login_code_path, params: { code: code }
    cookies[session_cookie] = cookie_before

    travel SignInCompletion::REPEAT_WINDOW + 1.second do
      post verify_login_code_path, params: { code: code }
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(session[:user_id]).to be_nil
  end

  it "refuses a different code sent with the cookie from before the sign-in" do
    code = request_code
    cookie_before = cookies[session_cookie]
    post verify_login_code_path, params: { code: code }
    cookies[session_cookie] = cookie_before

    post verify_login_code_path, params: { code: wrong_code_for(code) }

    expect(response).to have_http_status(:unprocessable_content)
    expect(session[:user_id]).to be_nil
  end

  it "refuses the redeemed code from another browser, which never had this sign-in pending" do
    code = request_code
    post verify_login_code_path, params: { code: code }

    other = open_session
    other.post login_path, params: { email: user.email }
    other.post verify_login_code_path, params: { code: code }

    expect(other.response).to have_http_status(:unprocessable_content)
    expect(other.session[:user_id]).to be_nil
  end

  it "accepts the repeat when the code was mailed late, though the first post ended the pending sign-in's life" do
    post login_path, params: { email: user.email }
    code = travel(3.minutes) { user.generate_login_code! }

    travel(12.minutes) { post_twice(verify_login_code_path, { code: code }) }

    expect(response).to redirect_to(root_path)
    expect(session[:user_id]).to eq(user.id)
  end

  it "counts repeats from many addresses against one account once a late code ended the pending sign-in" do
    post login_path, params: { email: user.email }
    code = travel(3.minutes) { user.generate_login_code! }
    cookie_before = cookies[session_cookie]

    statuses = travel(12.minutes) do
      post verify_login_code_path, params: { code: code }
      Array.new(10) do |n|
        cookies[session_cookie] = cookie_before
        post verify_login_code_path, params: { code: wrong_code_for(code) }, env: { "REMOTE_ADDR" => "203.0.113.#{n + 1}" }
        response.status
      end
    end

    expect(statuses.last).to eq(429)
  end

  it "refuses the repeat once the account's sessions were ended after the first post" do
    code = request_code
    cookie_before = cookies[session_cookie]
    post verify_login_code_path, params: { code: code }
    cookies[session_cookie] = cookie_before
    travel(1.second) { user.update!(sessions_valid_after: Time.current.floor(6)) }

    travel(2.seconds) { post verify_login_code_path, params: { code: code } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(session[:user_id]).to be_nil
  end

  context "with the authenticator on" do
    let!(:enrollment) { enroll_second_factor(user) }
    let(:secret) { enrollment.first }

    it "sends a repeated emailed code to the authenticator step, never past it" do
      code = request_code

      post_twice(verify_login_code_path, { code: code })

      expect(response).to redirect_to(second_factor_challenge_path)
      expect(session[:user_id]).to be_nil
    end

    it "signs in on the second post of an authenticator code the first post just accepted" do
      post login_path, params: { email: user.email }
      post verify_login_code_path, params: { code: user.generate_login_code! }

      first = post_twice(second_factor_challenge_path, { otp_code: current_totp(secret) })

      expect(first).to redirect_to(root_path)
      expect(response).to redirect_to(root_path)
      expect(session[:user_id]).to eq(user.id)
    end

    it "signs in a duplicate that passed the open-challenge check before the first post closed it" do
      post login_path, params: { email: user.email }
      post verify_login_code_path, params: { code: user.generate_login_code! }
      otp = current_totp(secret)
      cookie_before = cookies[session_cookie]
      post second_factor_challenge_path, params: { otp_code: otp }
      cookies[session_cookie] = cookie_before
      allow_any_instance_of(User).to receive(:second_factor_challenge_open?).and_return(true, false)

      post second_factor_challenge_path, params: { otp_code: otp }

      expect(response).to redirect_to(root_path)
      expect(session[:user_id]).to eq(user.id)
    end

    it "gives both posts of a repeated emailed code the same authenticator challenge" do
      code = request_code
      cookie_before = cookies[session_cookie]
      post verify_login_code_path, params: { code: code }
      first_marker = session[:pending_second_factor]
      cookies[session_cookie] = cookie_before

      post verify_login_code_path, params: { code: code }

      expect(response).to redirect_to(second_factor_challenge_path)
      expect(session[:pending_second_factor]).to eq(first_marker)
      expect(user.reload.second_factor_challenge_open?(first_marker["at"])).to be(true)
    end

    it "keeps a pending trial when a repeated emailed code still needs the authenticator step" do
      stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key")
      trial_user = User.create!(email: "trial@example.com", name: "Trial", track_chosen_at: Time.current)
      trial_secret, _codes = enroll_second_factor(trial_user)
      invite, invite_code = mint_trial_code
      post start_trial_path, params: { email: trial_user.email, invite_code: invite_code, provider: "fake", consent: "1" }

      post_twice(verify_login_code_path, { code: trial_user.generate_login_code! })
      post second_factor_challenge_path, params: { otp_code: current_totp(trial_secret) }

      expect(flash[:notice]).to eq("Your trial has started.")
      expect(trial_user.reload.invite_code).to eq(invite)
    end

    it "counts replayed authenticator guesses against the rate limits" do
      post login_path, params: { email: user.email }
      post verify_login_code_path, params: { code: user.generate_login_code! }
      cookie_before = cookies[session_cookie]
      post second_factor_challenge_path, params: { otp_code: current_totp(secret) }
      wrong = wrong_code_for(current_totp(secret))

      statuses = Array.new(10) do
        cookies[session_cookie] = cookie_before
        post second_factor_challenge_path, params: { otp_code: wrong }
        response.status
      end

      expect(statuses.last).to eq(429)
      expect(session[:user_id]).to be_nil
    end

    it "refuses a different authenticator code sent with the cookie from before the sign-in" do
      post login_path, params: { email: user.email }
      post verify_login_code_path, params: { code: user.generate_login_code! }
      cookie_before = cookies[session_cookie]
      post second_factor_challenge_path, params: { otp_code: current_totp(secret) }
      cookies[session_cookie] = cookie_before

      post second_factor_challenge_path, params: { otp_code: enrollment.last.first }

      expect(response).to redirect_to(login_path)
      expect(session[:user_id]).to be_nil
    end
  end
end
