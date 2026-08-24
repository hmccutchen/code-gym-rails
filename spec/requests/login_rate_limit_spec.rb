require "rails_helper"

# The test environment uses :null_store, whose #increment returns nil, so
# Rails' rate limiter never trips there and the rest of the suite can log in
# freely. These examples swap in a real store to exercise the limits.
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

    # Keyed on the address, not the browser: the whole point is to cap how
    # many fresh codes one target can be made to generate.
    it "counts requests for one address across separate sessions" do
      5.times { post login_path, params: { email: "dev@example.com", name: "Dev" } }

      other_jar = open_session
      expect {
        other_jar.post login_path, params: { email: "dev@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)
    end

    # Proves the by: lambda normalizes exactly like #create does — a limit
    # that normalized differently would let case or whitespace evade it.
    it "shares one bucket for an address regardless of case or whitespace" do
      5.times { post login_path, params: { email: "dev@example.com", name: "Dev" } }

      expect {
        post login_path, params: { email: " DEV@Example.com " }
      }.not_to have_enqueued_mail(UserMailer, :login_code)
    end

    # The two rate_limit declarations need distinct `name:`s or they alias:
    # nameless, both key on `by`, and `by` for #create is attacker-controlled,
    # so submitting the request's own IP as the email makes both limits key
    # on "127.0.0.1". Eleven such posts land the shared key at 11 (posts
    # 6-11 are themselves over #create's cap of 5, but rate_limit increments
    # before it checks, so they still count) — the next verify post would
    # then be the 12th and trip #verify_code's cap of 10. With separate
    # names, #create's posts land in "code_requests:127.0.0.1" and the verify
    # post opens a fresh "code_attempts:127.0.0.1" at 1, so it answers
    # normally instead of 429.
    # Bounds an attacker who varies the address instead of hammering one —
    # the address-keyed limit above can't see that pattern at all, since each
    # address gets its own fresh bucket.
    it "stops a 21st request from one IP across 21 different addresses" do
      20.times { |n| post login_path, params: { email: "dev#{n}@example.com", name: "Dev" } }

      expect {
        post login_path, params: { email: "dev20@example.com" }
      }.not_to have_enqueued_mail(UserMailer, :login_code)

      expect(flash[:alert]).to match(/too many/i)
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include('name="email"')
    end

    it "keeps the create and verify_code buckets separate when an attacker submits their IP as the email" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      user = User.find_by(email: "dev@example.com")
      wrong = wrong_code_for(user.generate_login_code!)

      11.times { post login_path, params: { email: "127.0.0.1" } }

      post verify_login_code_path, params: { code: wrong }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "submitting codes" do
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
