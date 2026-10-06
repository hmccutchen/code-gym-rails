require "rails_helper"

RSpec.describe "Trials", type: :request do
  let(:user) { User.create!(email: "new@example.com", name: "New", time_zone: "America/New_York", learning_track: LearningTrack::OFF) }

  before { stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key") }

  def redeem(code, consent: "1")
    post trial_path, params: { invite_code: code, consent: consent }
  end

  it "sends an account with no key to Setup, and shows the redemption form with the data notice" do
    login_as(user)
    get root_path
    expect(response).to redirect_to(setup_path)

    get trial_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="invite_code"', 'name="consent"')
    expect(response.body).to include("Claude or Gemini", "Don&#39;t paste anything confidential", "up to 30 days")
  end

  it "starts the trial with consent, taking one seat, and then generates on demand" do
    invite, code = mint_trial_code(provider: "fake", seats: 1, days: 7, cap: 12)
    login_as(user)

    travel_to(Time.utc(2026, 10, 7, 14)) do
      redeem(code.downcase)
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq("Your trial has started.")

      user.reload
      expect(user.provider).to eq("fake")
      expect(user.api_keys).to be_nil
      expect(user.invite_code).to eq(invite)
      expect(user.trial_consented_at).to be_within(1.second).of(Time.current)
      expect(user.trial_ends_at).to eq(Time.utc(2026, 10, 14, 3, 59, 59, 999_999))
      expect(user).to be_trial_active
      expect(invite.reload.redeemed_count).to eq(1)

      expect { get root_path }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)
      get trial_path
      expect(response.body).to include("Your trial runs until the end of October 13, 2026: 7 days left.")
      expect(response.body).not_to include('name="invite_code"')
    end
  end

  it "refuses an account that has a key of its own, taking no seat" do
    invite, code = mint_trial_code(provider: "fake")
    own = create_user_with_key(email: "own@example.com")
    login_as(own)

    redeem(code)

    expect(response).to redirect_to(setup_path)
    expect(flash[:alert]).to eq("You already have an API key, so you don't need a trial.")
    expect(invite.reload.redeemed_count).to eq(0)
    expect(own.reload.start_trial!(code: code, consented_at: Time.current)).to be(false)
  end

  it "refuses without consent, saving nothing" do
    _invite, code = mint_trial_code(provider: "fake")
    login_as(user)

    redeem(code, consent: "0")

    expect(response).to redirect_to(trial_path)
    expect(flash[:alert]).to eq("Tick the box to confirm you've read what is sent on a trial.")
    expect(user.reload).not_to be_trial
  end

  it "answers a wrong, expired, exhausted or join code with one sentence" do
    login_as(user)
    expired, expired_code = mint_trial_code(provider: "fake", expires_at: 1.day.ago)
    full, full_code = mint_trial_code(provider: "fake", seats: 1)
    full.redeem!

    [ "NOPE", expired_code, full_code, mint_join_code ].each do |code|
      redeem(code)
      expect(response).to redirect_to(trial_path)
      expect(flash[:alert]).to eq("That code didn't work. Check it and try again, or ask the person who gave it to you.")
      expect(user.reload).not_to be_trial
    end
    expect(expired.reload.redeemed_count).to eq(0)
  end

  it "refuses a second trial on an account that has one" do
    _first, first_code = mint_trial_code(provider: "fake")
    _second, second_code = mint_trial_code(provider: "fake")
    login_as(user)
    redeem(first_code)

    redeem(second_code)

    expect(flash[:alert]).to start_with("That code didn't work.")
    expect(InviteCode.sum(:redeemed_count)).to eq(1)
  end

  it "lets an account that signed up with a trial code consent without typing it again" do
    invite, code = mint_trial_code(provider: "fake", seats: 1)
    post login_path, params: { email: "signup@example.com", name: "Signup", invite_code: code }
    signed_up = User.find_by!(email: "signup@example.com")
    expect(signed_up.invite_code).to eq(invite)
    expect(signed_up).to be_trial_pending
    signed_up.update!(learning_track: LearningTrack::OFF)
    login_as(signed_up)

    get root_path
    expect(response).to redirect_to(trial_path)
    get trial_path
    expect(response.body).not_to include('name="invite_code"')
    expect(response.body).to include("to AI using a key")

    post trial_path, params: { consent: "1" }

    expect(signed_up.reload).to be_trial_active
    expect(invite.reload.redeemed_count).to eq(1)
  end

  it "limits redemption attempts per account" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    login_as(user)

    5.times { redeem("NOPE") }
    redeem("NOPE")

    expect(response).to redirect_to(trial_path)
    expect(flash[:alert]).to eq("Too many attempts. Try again in an hour.")
  end
end
