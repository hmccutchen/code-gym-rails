require "rails_helper"

RSpec.describe "Second-factor sign-in", type: :request do
  let(:user) { create_user_with_key(email: "dev@example.com") }
  let!(:enrollment) { enroll_second_factor(user) }
  let(:secret) { enrollment.first }
  let(:recovery_codes) { enrollment.last }
  let(:session_cookie) { "_code_gym_rails_session" }

  def enter_email
    post login_path, params: { email: user.email }
  end

  def wrong_totp
    valid = (-1..1).map { |offset| current_totp(secret, at: Time.current + (offset * User::TOTP_INTERVAL).seconds) }
    (0..3).map { |n| format("%06d", n) }.find { |candidate| valid.exclude?(candidate) }
  end

  def answer(code)
    post second_factor_challenge_path, params: { otp_code: code }
  end

  it "sends the email address straight to the second step without signing in or mailing a code" do
    expect { enter_email }.not_to have_enqueued_mail(UserMailer, :login_code)

    expect(response).to redirect_to(second_factor_challenge_path)
    expect(session[:user_id]).to be_nil
    expect(session[:pending_login_email]).to be_nil
    get history_path
    expect(response).to redirect_to(login_path)
  end

  it "shows one code field named otp_code" do
    enter_email
    follow_redirect!

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="otp_code"', 'autocomplete="one-time-code"')
    expect(response.body).not_to include("autofocus")
  end

  it "signs in with a TOTP and runs the full session reset" do
    enter_email

    answer(current_totp(secret))

    expect(response).to redirect_to(root_path)
    expect(session.to_hash.keys - %w[session_id flash _csrf_token]).to contain_exactly("user_id", "signed_in_at")
    expect(user.reload.second_factor_challenge_at).to be_nil
  end

  it "signs in with a recovery code and says how many are left" do
    enter_email

    answer(recovery_codes.first)

    expect(response).to redirect_to(root_path)
    expect(session[:user_id]).to eq(user.id)
    expect(flash[:notice]).to eq("You signed in with a recovery code. You have 9 recovery codes left.")
  end

  it "re-renders the page after a wrong code" do
    enter_email

    answer(wrong_totp)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("That code didn&#39;t work", 'name="otp_code"')
    expect(session[:user_id]).to be_nil
  end

  it "ends the challenge on the row after five wrong codes" do
    enter_email

    5.times { answer(wrong_totp) }

    expect(response).to redirect_to(login_path)
    expect(flash[:alert]).to match(/too many wrong codes/i)
    expect(session[:pending_second_factor]).to be_nil
    expect(user.reload.second_factor_challenge_at).to be_nil
  end

  it "keeps counting when an earlier copy of the cookie is replayed" do
    enter_email
    saved_cookie = cookies[session_cookie]

    4.times { answer(wrong_totp) }
    cookies[session_cookie] = saved_cookie
    answer(wrong_totp)

    expect(response).to redirect_to(login_path)
    expect(user.reload.second_factor_challenge_at).to be_nil
    cookies[session_cookie] = saved_cookie
    answer(current_totp(secret))
    expect(response).to redirect_to(login_path)
    expect(session[:user_id]).to be_nil
  end

  it "sends an expired challenge back to the login page" do
    enter_email

    travel User::SECOND_FACTOR_CHALLENGE_LIFETIME + 1.second do
      answer(current_totp(secret))
    end

    expect(response).to redirect_to(login_path)
    expect(flash[:alert]).to match(/timed out/)
    expect(session[:user_id]).to be_nil
  end

  it "sends a visit with no challenge back to the login page" do
    get second_factor_challenge_path

    expect(response).to redirect_to(login_path)
  end

  it "keeps return_to through the second step" do
    get history_path
    enter_email

    answer(current_totp(secret))

    expect(response).to redirect_to(history_path)
  end

  it "keeps a pending trial through the second step" do
    stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key")
    trial_user = User.create!(email: "trial@example.com", name: "Trial", track_chosen_at: Time.current)
    trial_secret, _codes = enroll_second_factor(trial_user)
    invite, code = mint_trial_code
    post start_trial_path, params: { email: trial_user.email, invite_code: code, provider: "fake", consent: "1" }
    post verify_login_code_path, params: { code: trial_user.generate_login_code! }
    expect(response).to redirect_to(second_factor_challenge_path)

    answer(current_totp(trial_secret))

    expect(flash[:notice]).to eq("Your trial has started.")
    expect(trial_user.reload.invite_code).to eq(invite)
  end

  it "shows when to try again once the daily cap is reached" do
    user.update!(second_factor_failures: User::SECOND_FACTOR_DAILY_FAILURES, second_factor_failures_since: 1.hour.ago)
    enter_email

    answer(current_totp(secret))

    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).to include("too many wrong authenticator codes in the last day")
    expect(response.body).not_to include('name="otp_code"')
    expect(session[:user_id]).to be_nil
    expect(user.reload.second_factor_challenge_at).to be_nil
  end

  it "leaves sign-in unchanged for an account with the authenticator off" do
    other = create_user_with_key(email: "plain@example.com")
    post login_path, params: { email: other.email }
    post verify_login_code_path, params: { code: other.generate_login_code! }

    expect(response).to redirect_to(root_path)
    expect(session[:user_id]).to eq(other.id)
    expect(session[:signed_in_at]).to be_present
  end

  describe "rate limits" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    def wrong_answers_across_challenges(count)
      count.times do |n|
        if (n % 4).zero?
          travel User::DOUBLE_TAP_WINDOW + 1.second if n.positive?
          enter_email
        end
        answer(wrong_totp)
      end
    end

    it "stops an eleventh attempt for one pending account" do
      wrong_answers_across_challenges(10)

      answer(current_totp(secret))

      expect(response).to have_http_status(:too_many_requests)
      expect(session[:user_id]).to be_nil
    end

    it "stops a twenty-first attempt from one address across accounts" do
      others = (1..2).map { |n| create_user_with_key(email: "other#{n}@example.com").tap { enroll_second_factor(_1) } }
      [ user, *others ].each do |account|
        7.times do |n|
          if (n % 4).zero?
            post login_path, params: { email: account.email }
          end
          answer("000000")
        end
      end

      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
