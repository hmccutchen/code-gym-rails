require "rails_helper"

# :null_store never trips rate limits, so these examples swap in a real store.
RSpec.describe "Login rate limits", type: :request do
  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  describe "requesting codes" do
    it "stops a sixth request for the same address inside the window" do
      5.times { post login_path, params: { email: "dev@example.com", name: "Dev" } }

      expect {
        post login_path, params: { email: "dev@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)

      expect(flash[:alert]).to match(/too many/i)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include('name="email"')
    end

    # The earlier requests left a code pending, so the page still shows the code field.
    it "keeps the refused request's message off the pending code field" do
      5.times do
        post login_path, params: { email: "dev@example.com", name: "Dev" }
        follow_redirect!
      end
      post login_path, params: { email: "dev@example.com" }

      expect(response).to have_http_status(:too_many_requests)
      field = Nokogiri::HTML(response.body).at_css("input[name=code]")
      expect(field["aria-describedby"].split).to eq(%w[pending-message])
      expect(field["aria-invalid"]).to be_nil
    end

    # Keyed on the address, to cap how many fresh codes one target can be made to generate.
    it "counts requests for one address across separate sessions" do
      5.times { post login_path, params: { email: "dev@example.com", name: "Dev" } }

      other_jar = open_session
      expect {
        other_jar.post login_path, params: { email: "dev@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)
    end

    # The by: lambda must normalize like #create, or case and whitespace would evade the limit.
    it "shares one bucket for an address regardless of case or whitespace" do
      5.times { post login_path, params: { email: "dev@example.com", name: "Dev" } }

      expect {
        post login_path, params: { email: " DEV@Example.com " }
      }.not_to have_enqueued_mail(UserMailer, :login_code)
    end

    # The address-keyed limit cannot see an attacker who varies the address.
    it "stops a 21st request from one IP across 21 different addresses" do
      20.times { |n| post login_path, params: { email: "dev#{n}@example.com", name: "Dev" } }

      expect {
        post login_path, params: { email: "dev20@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)

      expect(flash[:alert]).to match(/too many/i)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include('name="email"')
    end

    # Without distinct names both limits key on the attacker-supplied IP-as-email and share one bucket.
    it "keeps the create and verify_code buckets separate when an attacker submits their IP as the email" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      user = User.find_by(email: "dev@example.com")
      wrong = wrong_code_for(user.generate_login_code!)

      11.times { post login_path, params: { email: "127.0.0.1" } }

      post verify_login_code_path, params: { code: wrong }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "creating accounts from one IP over a day" do
    it "stops a 51st request from one IP in a day" do
      50.times do |n|
        travel(16.minutes) if (n % 20).zero? && n.positive?
        post login_path, params: { email: "dev#{n}@example.com", name: "Dev" }
      end

      expect {
        post login_path, params: { email: "dev50@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "submitting codes" do
    # Rotating IPs each get a bucket, so only an address-keyed limit bounds guesses at one account.
    it "stops an eleventh guess at one address even when each guess comes from a new IP" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      wrong = wrong_code_for(User.find_by(email: "dev@example.com").generate_login_code!)

      10.times { |n| post verify_login_code_path, params: { code: wrong }, env: { "REMOTE_ADDR" => "10.0.0.#{n + 1}" } }
      post verify_login_code_path, params: { code: wrong }, env: { "REMOTE_ADDR" => "10.0.0.99" }

      expect(response).to have_http_status(:too_many_requests)
      expect(flash[:alert]).to match(/too many/i)
    end

    it "keeps one address's guesses from limiting another address" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      wrong = wrong_code_for(User.find_by(email: "dev@example.com").generate_login_code!)
      10.times { |n| post verify_login_code_path, params: { code: wrong }, env: { "REMOTE_ADDR" => "10.0.0.#{n + 1}" } }

      other = open_session
      other.post login_path, params: { email: "other@example.com", name: "Other" }, env: { "REMOTE_ADDR" => "10.0.1.1" }
      other.post verify_login_code_path, params: { code: "000000" }, env: { "REMOTE_ADDR" => "10.0.1.1" }

      expect(other.response).to have_http_status(:unprocessable_content)
    end

    it "stops an eleventh guess from one IP inside the window" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      user = User.find_by(email: "dev@example.com")
      wrong = wrong_code_for(user.generate_login_code!)

      10.times { post verify_login_code_path, params: { code: wrong } }
      post verify_login_code_path, params: { code: wrong }

      expect(flash[:alert]).to match(/too many/i)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include('name="email"')
    end

    # Nothing was checked, so the code is not marked invalid.
    it "describes the code field by the refusal without marking the code invalid" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      11.times { post verify_login_code_path, params: { code: "000000" } }

      expect(response).to have_http_status(:too_many_requests)
      field = Nokogiri::HTML(response.body).at_css("input[name=code]")
      expect(field["aria-describedby"].split).to eq(%w[flash-alert pending-message])
      expect(field["aria-invalid"]).to be_nil
    end
  end

  describe "the guessing ceiling beneath the limits" do
    it "invalidates the code after five wrong guesses" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      user = User.find_by(email: "dev@example.com")
      real_code = user.generate_login_code!
      wrong = wrong_code_for(real_code)

      5.times { post verify_login_code_path, params: { code: wrong } }
      post verify_login_code_path, params: { code: real_code }

      expect(session[:user_id]).to be_nil
    end
  end
end
