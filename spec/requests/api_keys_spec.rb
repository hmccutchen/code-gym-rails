require "rails_helper"

RSpec.describe "ApiKeys", type: :request do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  describe "PATCH /setup" do
    it "saves a valid Anthropic key, encrypted, and detects the provider" do
      login_as(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("sk-ant-api03-abc123")
      expect(user.provider).to eq("anthropic")
      expect(user.api_key_present?).to be true
    end

    it "saves a valid Gemini key and detects the provider" do
      login_as(user)

      patch setup_path, params: { api_key: "AIzaSyExampleKey12345" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("AIzaSyExampleKey12345")
      expect(user.provider).to eq("gemini")
    end

    it "saves a valid Gemini key in Google's newer AQ. format and detects the provider" do
      login_as(user)

      patch setup_path, params: { api_key: "AQ.Ab8RN6J5yPUsY9SwLxAS2DYq_cYQFIhR9xG8C0Dz3D9CdyL-qg" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.api_key).to eq("AQ.Ab8RN6J5yPUsY9SwLxAS2DYq_cYQFIhR9xG8C0Dz3D9CdyL-qg")
      expect(user.provider).to eq("gemini")
    end

    it "saves a valid language preference alongside the API key" do
      login_as(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123", language: "javascript" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("javascript")
    end

    it "ignores an invalid language value without blocking the API key save" do
      login_as(user)

      patch setup_path, params: { api_key: "sk-ant-api03-abc123", language: "python" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("ruby_rails")
      expect(user.api_key).to eq("sk-ant-api03-abc123")
    end

    it "defaults to the user's current language when no language param is given" do
      login_as(user)
      user.update!(language: "mixed")

      patch setup_path, params: { api_key: "sk-ant-api03-abc123" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("mixed")
    end

    it "rejects a key that doesn't look like either provider's key" do
      login_as(user)

      patch setup_path, params: { api_key: "not-a-real-key" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("We don&#39;t recognize this key format")
      expect(user.reload.api_key_present?).to be false
      expect(user.provider).to be_nil
    end

    it "updates only the language when the api_key field is blank and a key already exists" do
      user.update!(api_key: "sk-ant-existing", provider: "anthropic")
      login_as(user)

      patch setup_path, params: { api_key: "", language: "javascript" }

      expect(response).to redirect_to(root_path)
      expect(user.reload.language).to eq("javascript")
      expect(user.api_key).to eq("sk-ant-existing")
    end

    it "rejects a language-only update when no key has been set yet" do
      login_as(user)

      patch setup_path, params: { api_key: "", language: "javascript" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Add your API key")
      expect(user.reload.language).to eq("ruby_rails")
    end
  end

  describe "GET /setup" do
    it "renders a weight control and an exclude toggle for every rotatable kind" do
      login_as(user)

      get setup_path

      ExerciseSection.rotatable.each do |kind|
        expect(response.body).to include(%(id="weight-#{kind.key}"))
        expect(response.body).to include(%(id="exclude-#{kind.key}"))
        expect(response.body).to include(I18n.t("sections.#{kind.key}.name"))
      end
    end

    it "renders the stops from the constant rather than restating them" do
      login_as(user)

      get setup_path

      expect(response.body).to include(KindPreferences::MULTIPLIERS.to_json)
    end

    # The copy is load-bearing: the two controls mean different things, and a
    # slider at its minimum provably cannot mean "never" while the starvation
    # guarantee stands.
    it "says excluding is a different action from a low weight" do
      login_as(user)

      get setup_path

      expect(response.body).to include("stronger, different action")
    end

    it "reflects stored preferences in the rendered controls" do
      login_as(user)
      user.update!(section_kind_weights: { "challenge" => 4.0 }, excluded_section_kinds: [ "parsons_problem" ])

      get setup_path

      doc = Nokogiri::HTML(response.body)

      expect(doc.at("#weight-challenge")["value"]).to eq("4")
      expect(doc.at("#exclude-parsons_problem")["checked"]).to be_present
      expect(doc.at("#weight-parsons_problem")["disabled"]).to be_present
    end
  end
end
