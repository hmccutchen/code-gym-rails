require "rails_helper"

# :null_store never trips rate limits, so these examples swap in a real store.
RSpec.describe "Login rate limits", type: :request do
  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    %w[dev@example.com other@example.com].each { |email| User.create!(email: email, name: "Waiting") }
  end

  describe "signing in with a password" do
    let(:user) { enroll_two_factor(create_user_with_key(email: "pw@example.com")) }

    def attempt(password: "wrong password here", ip: "127.0.0.1")
      post user_session_path, params: { user: { email: user.email, password: password, otp_attempt: "000000" } },
                              env: { "REMOTE_ADDR" => ip }
    end

    it "stops an eleventh attempt at one address even when each comes from a new IP" do
      10.times { |n| attempt(ip: "10.0.0.#{n + 1}") }

      post user_session_path, params: { user: { email: user.email, password: AuthHelpers::SPEC_PASSWORD,
                                                otp_attempt: user.current_otp } }, env: { "REMOTE_ADDR" => "10.0.0.99" }

      expect(response).to have_http_status(:too_many_requests)
      expect(session["warden.user.user.key"]).to be_nil
      expect(response.body).to include('name="user[email]"')
    end

    it "stops a 21st attempt from one IP across many addresses" do
      20.times { |n| post user_session_path, params: { user: { email: "dev#{n}@example.com", password: "x" } } }

      attempt

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "requesting codes" do
    it "stops a sixth request for the same address inside the window" do
      5.times { post first_sign_in_path, params: { email: "dev@example.com" } }

      expect {
        post first_sign_in_path, params: { email: "dev@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)

      expect(flash[:alert]).to match(/too many/i)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include('name="email"')
    end

    it "keeps the refused request's message off the pending code field" do
      5.times do
        post first_sign_in_path, params: { email: "dev@example.com" }
        follow_redirect!
      end
      post first_sign_in_path, params: { email: "dev@example.com" }

      expect(response).to have_http_status(:too_many_requests)
      field = Nokogiri::HTML(response.body).at_css("input[name=code]")
      expect(field["aria-describedby"].split).to eq(%w[pending-message])
      expect(field["aria-invalid"]).to be_nil
    end

    it "counts requests for one address across separate sessions" do
      5.times { post first_sign_in_path, params: { email: "dev@example.com" } }

      other_jar = open_session
      expect {
        other_jar.post first_sign_in_path, params: { email: "dev@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)
    end

    # The by: lambda must normalize like #create, or case and whitespace would evade the limit.
    it "shares one bucket for an address regardless of case or whitespace" do
      5.times { post first_sign_in_path, params: { email: "dev@example.com" } }

      expect {
        post first_sign_in_path, params: { email: " DEV@Example.com " }
      }.not_to have_enqueued_mail(UserMailer, :login_code)
    end

    # The address-keyed limit cannot see an attacker who varies the address.
    it "stops a 21st request from one IP across 21 different addresses" do
      20.times { |n| post first_sign_in_path, params: { email: "dev#{n}@example.com" } }

      expect {
        post first_sign_in_path, params: { email: "dev20@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)

      expect(flash[:alert]).to match(/too many/i)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include('name="email"')
    end

    # Without distinct names both limits key on the attacker-supplied IP-as-email and share one bucket.
    it "keeps the create and verify_code buckets separate when an attacker submits their IP as the email" do
      post first_sign_in_path, params: { email: "dev@example.com" }
      user = User.find_by(email: "dev@example.com")
      wrong = wrong_code_for(user.generate_login_code!)

      11.times { post first_sign_in_path, params: { email: "127.0.0.1" } }

      post verify_first_sign_in_path, params: { code: wrong }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "submitting codes" do
    # Rotating IPs each get a bucket, so only an address-keyed limit bounds guesses at one account.
    it "stops an eleventh guess at one address even when each guess comes from a new IP" do
      post first_sign_in_path, params: { email: "dev@example.com" }
      wrong = wrong_code_for(User.find_by(email: "dev@example.com").generate_login_code!)

      10.times { |n| post verify_first_sign_in_path, params: { code: wrong }, env: { "REMOTE_ADDR" => "10.0.0.#{n + 1}" } }
      post verify_first_sign_in_path, params: { code: wrong }, env: { "REMOTE_ADDR" => "10.0.0.99" }

      expect(response).to have_http_status(:too_many_requests)
      expect(flash[:alert]).to match(/too many/i)
    end

    it "keeps one address's guesses from limiting another address" do
      post first_sign_in_path, params: { email: "dev@example.com" }
      wrong = wrong_code_for(User.find_by(email: "dev@example.com").generate_login_code!)
      10.times { |n| post verify_first_sign_in_path, params: { code: wrong }, env: { "REMOTE_ADDR" => "10.0.0.#{n + 1}" } }

      other = open_session
      other.post first_sign_in_path, params: { email: "other@example.com" }, env: { "REMOTE_ADDR" => "10.0.1.1" }
      other.post verify_first_sign_in_path, params: { code: "000000" }, env: { "REMOTE_ADDR" => "10.0.1.1" }

      expect(other.response).to have_http_status(:unprocessable_content)
    end

    it "stops an eleventh guess from one IP inside the window" do
      post first_sign_in_path, params: { email: "dev@example.com" }
      user = User.find_by(email: "dev@example.com")
      wrong = wrong_code_for(user.generate_login_code!)

      10.times { post verify_first_sign_in_path, params: { code: wrong } }
      post verify_first_sign_in_path, params: { code: wrong }

      expect(flash[:alert]).to match(/too many/i)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include('name="email"')
    end

    it "describes the code field by the refusal without marking the code invalid, since nothing was checked" do
      post first_sign_in_path, params: { email: "dev@example.com" }
      11.times { post verify_first_sign_in_path, params: { code: "000000" } }

      expect(response).to have_http_status(:too_many_requests)
      field = Nokogiri::HTML(response.body).at_css("input[name=code]")
      expect(field["aria-describedby"].split).to eq(%w[flash-alert pending-message])
      expect(field["aria-invalid"]).to be_nil
    end
  end

  describe "the guessing ceiling beneath the limits" do
    it "invalidates the code after five wrong guesses" do
      post first_sign_in_path, params: { email: "dev@example.com" }
      user = User.find_by(email: "dev@example.com")
      real_code = user.generate_login_code!
      wrong = wrong_code_for(real_code)

      5.times { post verify_first_sign_in_path, params: { code: wrong } }
      post verify_first_sign_in_path, params: { code: real_code }

      expect(session["warden.user.user.key"]).to be_nil
    end
  end
end
