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

    it "leaves a different address unaffected" do
      5.times { post login_path, params: { email: "dev@example.com", name: "Dev" } }

      expect {
        post login_path, params: { email: "other@example.com", name: "Other" }
      }.to have_enqueued_mail(UserMailer, :login_code)
    end
  end

  describe "submitting codes" do
    it "stops an eleventh guess from one IP inside the window" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }

      10.times { post verify_login_code_path, params: { code: "000000" } }
      post verify_login_code_path, params: { code: "000000" }

      expect(flash[:alert]).to match(/too many/i)
    end
  end

  describe "the guessing ceiling beneath the limits" do
    it "invalidates the code after five wrong guesses" do
      post login_path, params: { email: "dev@example.com", name: "Dev" }
      user = User.find_by(email: "dev@example.com")
      real_code = user.generate_login_code!

      5.times { post verify_login_code_path, params: { code: "000000" } }
      post verify_login_code_path, params: { code: real_code }

      expect(session[:user_id]).to be_nil
    end
  end
end
