require "rails_helper"

RSpec.describe "ApiKeys", type: :request do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  def login(user)
    get verify_auth_path(token: user.generate_login_token!)
  end

  describe "PATCH /setup" do
    it "saves a valid Anthropic key, encrypted, and detects the provider" do
      login(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("sk-ant-api03-abc123")
      expect(user.provider).to eq("anthropic")
      expect(user.api_key_present?).to be true
    end

    it "saves a valid Gemini key and detects the provider" do
      login(user)

      patch setup_path, params: { api_key: "AIzaSyExampleKey12345" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("AIzaSyExampleKey12345")
      expect(user.provider).to eq("gemini")
    end

    it "rejects a key that doesn't look like either provider's key" do
      login(user)

      patch setup_path, params: { api_key: "not-a-real-key" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("We don&#39;t recognize this key format")
      expect(user.reload.api_key_present?).to be false
      expect(user.provider).to be_nil
    end
  end
end
