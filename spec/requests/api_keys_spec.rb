require "rails_helper"

RSpec.describe "ApiKeys", type: :request do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  def login(user)
    login_as(user)
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

    it "saves a valid Gemini key in Google's newer AQ. format and detects the provider" do
      login(user)

      patch setup_path, params: { api_key: "AQ.Ab8RN6J5yPUsY9SwLxAS2DYq_cYQFIhR9xG8C0Dz3D9CdyL-qg" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("AQ.Ab8RN6J5yPUsY9SwLxAS2DYq_cYQFIhR9xG8C0Dz3D9CdyL-qg")
      expect(user.provider).to eq("gemini")
    end

    it "saves a valid language preference alongside the API key" do
      login(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123", language: "javascript" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("javascript")
    end

    it "ignores an invalid language value without blocking the API key save" do
      login(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123", language: "python" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("ruby_rails")
      expect(user.api_key).to eq("sk-ant-api03-abc123")
    end

    it "defaults to the user's current language when no language param is given" do
      login(user)
      user.update!(language: "mixed")

      patch setup_path, params: { api_key: "sk-ant-api03-abc123" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("mixed")
    end

    it "rejects a key that doesn't look like either provider's key" do
      login(user)

      patch setup_path, params: { api_key: "not-a-real-key" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("We don&#39;t recognize this key format")
      expect(user.reload.api_key_present?).to be false
      expect(user.provider).to be_nil
    end

    it "updates only the language when the api_key field is blank and a key already exists" do
      user.update!(api_key: "sk-ant-existing", provider: "anthropic")
      login(user)

      patch setup_path, params: { api_key: "", language: "javascript" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("javascript")
      expect(user.api_key).to eq("sk-ant-existing")
    end

    it "rejects a language-only update when no key has been set yet" do
      login(user)

      patch setup_path, params: { api_key: "", language: "javascript" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Add your API key")
      expect(user.reload.language).to eq("ruby_rails")
    end
  end
end
