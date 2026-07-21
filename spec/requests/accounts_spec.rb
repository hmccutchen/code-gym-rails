require "rails_helper"

RSpec.describe "Accounts", type: :request do
  describe "GET /account" do
    it "shows the identity summary, log out control and settings link" do
      user = create_user_with_key(email: "dev@example.com", name: "Dev")
      login_as(user)

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dev@example.com")
      expect(response.body).to include("Log out")
      expect(response.body).to include(setup_path)
    end

    # `AccountsController` skips `require_api_key` on purpose: without that
    # skip a keyless user is bounced to /setup and — with the nav log-out
    # button gone — has no way to log out at all.
    it "renders for a user who has not added an API key yet" do
      user = User.create!(email: "keyless@example.com", name: "Keyless")
      login_as(user)

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("keyless@example.com")
    end

    it "redirects to login when logged out" do
      get account_path

      expect(response).to redirect_to(login_path)
    end
  end

  describe "nav" do
    it "links to the account page instead of showing a log out button" do
      login_as(create_user_with_key)

      get history_path

      expect(response.body).to include(account_path)
      expect(response.body).to include("Account")
    end
  end
end
