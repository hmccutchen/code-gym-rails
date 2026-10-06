require "rails_helper"

RSpec.describe "Trials", type: :request do
  before { stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key") }

  def start(email: "new@example.com", code:, provider: "fake", consent: "1", name: "New")
    post start_trial_path, params: { name: name, email: email, invite_code: code, provider: provider, consent: consent }
  end

  def emailed_code
    ActionMailer::Base.deliveries.last.body.encoded[/is:\s*(\d{6})/m, 1]
  end

  def start_and_verify(**options)
    perform_enqueued_jobs { start(**options) }
    post verify_login_code_path, params: { code: emailed_code }
  end

  describe "signed out, with an email and a code" do
    it "shows the form to anyone, with each provider that has a house key and its data notice" do
      stub_env("HOUSE_OPENAI_API_KEY" => "sk-house")

      get new_trial_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="email"', 'name="invite_code"', 'name="consent"')
      expect(response.body).to include('value="openai"', 'value="fake"')
      expect(response.body).not_to include('value="gemini"')
      expect(response.body).to include("OpenAI keeps API data for up to 30 days")
    end

    it "sends a signed-out visit to /trial to the start page" do
      get trial_path

      expect(response).to redirect_to(new_trial_path)
    end

    it "mails a login code and starts the trial on the chosen provider once the code is entered" do
      invite, code = mint_trial_code(seats: 1, days: 7, cap: 12)

      travel_to(Time.utc(2026, 10, 7, 14)) do
        expect { perform_enqueued_jobs { start(code: code.downcase) } }.to change(User, :count).by(1)
        expect(response).to redirect_to(login_path)
        expect(flash[:notice]).to include("Your trial starts when you enter it.")
        expect(invite.reload.redeemed_count).to eq(0)

        post verify_login_code_path, params: { code: emailed_code }

        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq("Your trial has started.")
        user = User.find_by!(email: "new@example.com")
        expect(user).to have_attributes(provider: "fake", api_keys: nil, invite_code: invite)
        expect(user).to be_trial_active
        expect(user.trial_consented_at).to be_within(1.second).of(Time.current)
        expect(invite.reload.redeemed_count).to eq(1)
      end
    end

    it "starts a trial on OpenAI when its house key is set" do
      stub_env("HOUSE_OPENAI_API_KEY" => "sk-house")
      _invite, code = mint_trial_code

      start_and_verify(code: code, provider: "openai")

      expect(User.find_by!(email: "new@example.com")).to have_attributes(provider: "openai", trial?: true)
    end

    it "refuses a wrong, expired or full code, missing consent or a provider with no key, mailing nothing" do
      _expired, expired_code = mint_trial_code(expires_at: 1.day.ago)
      full, full_code = mint_trial_code(seats: 1)
      full.redeem!
      _good, good_code = mint_trial_code

      refusals = {
        { code: "NOPE" } => "That code didn't work.",
        { code: expired_code } => "That code didn't work.",
        { code: full_code } => "That code didn't work.",
        { code: good_code, consent: "0" } => "Tick the box",
        { code: good_code, provider: "gemini" } => "Choose the provider your trial runs on."
      }
      refusals.each do |options, message|
        expect { start(**options) }.not_to have_enqueued_mail(UserMailer, :login_code)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(CGI.escapeHTML(message))
        expect(response.body).to include('value="new@example.com"')
      end
      expect(User.find_by(email: "new@example.com")).to be_nil
    end

    it "takes no seat for an account that has a key of its own, and sends it to Setup" do
      own = create_user_with_key(email: "own@example.com")
      invite, code = mint_trial_code

      start_and_verify(email: "own@example.com", code: code)

      expect(response).to redirect_to(setup_path)
      expect(flash[:alert]).to eq("You already have an API key, so you don't need a trial.")
      expect(invite.reload.redeemed_count).to eq(0)
      expect(own.reload).not_to be_trial
    end

    it "signs in without a trial when the last seat went between the form and the code" do
      invite, code = mint_trial_code(seats: 1)
      perform_enqueued_jobs { start(code: code) }
      invite.redeem!

      post verify_login_code_path, params: { code: emailed_code }

      expect(response).to redirect_to(trial_path)
      expect(flash[:alert]).to start_with("That code didn't work.")
      expect(User.find_by!(email: "new@example.com")).not_to be_trial
    end

    it "drops the trial when a plain login code is asked for afterwards" do
      invite, code = mint_trial_code
      start(code: code)
      perform_enqueued_jobs { post login_path, params: { email: "new@example.com" } }

      post verify_login_code_path, params: { code: emailed_code }

      expect(response).to redirect_to(root_path)
      expect(User.find_by!(email: "new@example.com")).not_to be_trial
      expect(invite.reload.redeemed_count).to eq(0)
    end

    it "counts code requests from the trial page and the login page together" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      _invite, code = mint_trial_code(seats: 10)

      3.times { post login_path, params: { email: "new@example.com" } }
      2.times { start(code: code) }
      start(code: code)

      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include("Too many code requests for that address.")
    end

    it "says trials are not available under the kill switch" do
      stub_env("TRIALS_DISABLED" => "1")

      get new_trial_path

      expect(response.body).to include("Trials aren&#39;t available right now.")
      expect(response.body).not_to include('name="invite_code"')
    end
  end

  describe "signed in, on an account with no key" do
    let(:user) { User.create!(email: "keyless@example.com", name: "Keyless", time_zone: "America/New_York", learning_track: LearningTrack::OFF) }

    def redeem(code, provider: "fake", consent: "1")
      post trial_path, params: { invite_code: code, provider: provider, consent: consent }
    end

    before { login_as(user) }

    it "sends the account to Setup, and offers the form on the trial page without asking for an email" do
      get root_path
      expect(response).to redirect_to(setup_path)

      get trial_path
      expect(response.body).to include('name="invite_code"', 'name="provider"', 'name="consent"')
      expect(response.body).not_to include('name="email"')
    end

    it "starts the trial with consent, taking one seat, and then generates on demand" do
      invite, code = mint_trial_code(seats: 1, days: 7)

      travel_to(Time.utc(2026, 10, 7, 14)) do
        redeem(code)

        expect(response).to redirect_to(root_path)
        expect(user.reload).to be_trial_active
        expect(user.trial_ends_at).to eq(Time.utc(2026, 10, 14, 3, 59, 59, 999_999))
        expect(invite.reload.redeemed_count).to eq(1)
        expect { get root_path }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)
      end
    end

    it "refuses without consent or a provider, and a bad or second code" do
      _first, first_code = mint_trial_code
      _second, second_code = mint_trial_code

      redeem(first_code, consent: "0")
      expect(flash[:alert]).to start_with("Tick the box")
      redeem(first_code, provider: "gemini")
      expect(flash[:alert]).to eq("Choose the provider your trial runs on.")
      redeem("NOPE")
      expect(flash[:alert]).to start_with("That code didn't work.")
      expect(user.reload).not_to be_trial

      redeem(first_code)
      redeem(second_code)
      expect(flash[:alert]).to start_with("That code didn't work.")
      expect(InviteCode.sum(:redeemed_count)).to eq(1)
    end

    it "refuses an account with a key of its own" do
      own = create_user_with_key(email: "own@example.com")
      invite, code = mint_trial_code
      login_as(own)

      redeem(code)

      expect(response).to redirect_to(setup_path)
      expect(invite.reload.redeemed_count).to eq(0)
    end

    it "limits redemption attempts per account" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      6.times { redeem("NOPE") }

      expect(response).to redirect_to(trial_path)
      expect(flash[:alert]).to eq("Too many attempts. Try again in an hour.")
    end
  end
end
