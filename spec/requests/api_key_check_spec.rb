require "rails_helper"

RSpec.describe "Checking a key when it is saved", :real_key_check, type: :request do
  PASTED = {
    "anthropic" => { service: ClaudeService, key: "sk-ant-api03-PastedSecret", label: "Claude",
                     rejection: [ 401, "anthropic_401_invalid_key.json" ] },
    "gemini"    => { service: GeminiService, key: "AIzaSyPastedSecret12345", label: "Gemini",
                     rejection: [ 400, "gemini_400_api_key_invalid.json" ] },
    "openai"    => { service: OpenaiService, key: "sk-proj-PastedSecretAb8RN6J5y", label: "GPT",
                     rejection: [ 401, "openai_401_invalid_key.json" ] }
  }.freeze

  let(:user) { User.create!(email: "dev@example.com", track_chosen_at: Time.current) }

  before { login_as(user) }

  def logged
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  PASTED.each do |provider, facts|
    describe "a pasted #{provider} key" do
      let(:label) { AiProvider.label(provider) }

      it "is saved with the usual notice when the provider accepts it, after one request" do
        requests = stub_key_check(facts[:service])

        patch setup_path, params: { api_key: facts[:key] }

        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq("API key saved. You're all set!")
        expect(user.reload.api_keys).to eq(provider => facts[:key])
        expect(user.provider).to eq(provider)
        expect(requests.size).to eq(1)
      end

      it "is not saved when the provider rejects it, and the form says so beside the user's other choices" do
        status, body = facts[:rejection]
        requests = stub_key_check(facts[:service], status: status, body: key_check_fixture(body))

        patch setup_path, params: { api_key: facts[:key], language: "javascript" }

        expect(response).to have_http_status(:unprocessable_content)
        page = Nokogiri::HTML(response.body)
        expect(page.at_css("#flash-alert").text).to eq("#{label} didn't accept your API key, so it wasn't saved. Check the key in Setup.")
        expect(page.at_css("select[name=language] option[selected]")["value"]).to eq("javascript")
        expect(page.at_css("input[name=api_key]")["value"]).to be_nil
        expect(user.reload.api_keys).to be_nil
        expect(user.provider).to be_nil
        expect(user.language).to eq("ruby_rails")
        expect(requests.size).to eq(1)
      end

      it "is saved with a warning when the provider refuses the check with a 403" do
        stub_key_check(facts[:service], status: 403, body: key_check_fixture("gemini_403_permission_denied.json"))

        patch setup_path, params: { api_key: facts[:key] }

        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq(
          "Saved, but #{label} refused the check. The key may be fine: a 403 can mean a region or account restriction. " \
          "If your first set fails, check your #{label} account."
        )
        expect(user.reload.api_key).to eq(facts[:key])
      end

      [ [ 429, "a 429" ], [ 500, "a 500" ], [ 503, "a 503" ], [ 404, "an answer it has no rule for" ] ].each do |status, name|
        it "is saved with a warning after #{name}, with no second request" do
          requests = stub_key_check(facts[:service], status: status)

          patch setup_path, params: { api_key: facts[:key] }

          expect(response).to redirect_to(root_path)
          expect(flash[:notice]).to eq("Saved, but #{label} didn't answer, so the key hasn't been checked.")
          expect(user.reload.api_key).to eq(facts[:key])
          expect(requests.size).to eq(1)
        end
      end

      it "is saved with a warning when the provider does not answer in time" do
        requests = stub_key_check(facts[:service], error: Faraday::TimeoutError)

        patch setup_path, params: { api_key: facts[:key] }

        expect(flash[:notice]).to eq("Saved, but #{label} didn't answer, so the key hasn't been checked.")
        expect(user.reload.api_key).to eq(facts[:key])
        expect(requests.size).to eq(1)
      end

      it "keeps the key out of the logs, whatever the provider answers" do
        status, body = facts[:rejection]
        stub_key_check(facts[:service], status: status, body: key_check_fixture(body))

        output = logged { patch setup_path, params: { api_key: facts[:key] } }

        expect(output).to include("[key_check] provider=#{provider} result=rejected")
        expect(output).not_to include(facts[:key])
      end
    end
  end

  describe "what a rejection leaves alone" do
    before do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-old", "openai" => "sk-proj-kept" },
                   generation_account_failures: KeyHold::AFTER)
    end

    it "keeps the stored keys, the provider in use and the key-hold count" do
      stub_key_check(ClaudeService, status: 401)

      patch setup_path, params: { api_key: "sk-ant-api03-PastedSecret" }

      user.reload
      expect(user.api_keys).to eq("anthropic" => "sk-ant-old", "openai" => "sk-proj-kept")
      expect(user.provider).to eq("anthropic")
      expect(user.generation_account_failures).to eq(KeyHold::AFTER)
    end

    it "keeps them when the rejected key is for a provider other than the one in use" do
      stub_key_check(GeminiService, status: 400, body: key_check_fixture("gemini_400_api_key_invalid.json"))

      patch setup_path, params: { api_key: "AIzaSyPastedSecret12345" }

      user.reload
      expect(user.api_keys.keys).to eq(%w[anthropic openai])
      expect(user.provider).to eq("anthropic")
      expect(user.generation_account_failures).to eq(KeyHold::AFTER)
    end

    it "shows the provider radios as they were, with the key in use still checked" do
      stub_key_check(ClaudeService, status: 401)

      patch setup_path, params: { api_key: "sk-ant-api03-PastedSecret" }

      expect(Nokogiri::HTML(response.body).at_css("#provider-choice input[checked]")["value"]).to eq("anthropic")
    end

    [ [ 200, "accepted" ], [ 403, "refused" ], [ 503, "unanswered" ] ].each do |status, result|
      it "resets the key-hold count once a key is saved after an #{result} check" do
        stub_key_check(ClaudeService, status: status)

        patch setup_path, params: { api_key: "sk-ant-api03-PastedSecret" }

        expect(user.reload.generation_account_failures).to eq(0)
        expect(user.api_keys["anthropic"]).to eq("sk-ant-api03-PastedSecret")
      end
    end
  end

  describe "saves that call no provider" do
    let!(:requests) { PASTED.values.flat_map { |facts| [ stub_key_check(facts[:service]) ] } }

    it "makes no request for a key whose prefix matches no provider" do
      patch setup_path, params: { api_key: "not-a-real-key" }

      expect(response.body).to include("We don&#39;t recognize this key format")
      expect(requests).to all(be_empty)
    end

    it "makes no request for a preferences-only save" do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-existing" })

      patch setup_path, params: { api_key: "  ", language: "javascript" }

      expect(flash[:notice]).to eq(I18n.t("flash.api_keys.preferences_saved"))
      expect(requests).to all(be_empty)
    end

    it "makes no request when only the provider in use is switched" do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-existing", "openai" => "sk-proj-kept" })

      patch setup_path, params: { api_key: "", provider: "openai" }

      expect(user.reload.provider).to eq("openai")
      expect(requests).to all(be_empty)
    end
  end

  describe "a trial account pasting a key of its own" do
    let(:user) { create_trial_user(provider: "gemini", house_key: "AIzaHouseKey") }

    it "is checked with the pasted key, outside the trial's allowance and its usage count" do
      requests = stub_key_check(GeminiService)
      allow(TrialAllowance).to receive(:check!)

      expect { patch setup_path, params: { api_key: "AIzaSyPastedSecret12345" } }.not_to change(ApiUsage, :count)

      expect(requests.first.request_headers["x-goog-api-key"]).to eq("AIzaSyPastedSecret12345")
      expect(TrialAllowance).not_to have_received(:check!)
      expect(user.reload.api_key).to eq("AIzaSyPastedSecret12345")
    end

    it "words a rejection as a problem with the pasted key, not the trial's" do
      stub_key_check(GeminiService, status: 400, body: key_check_fixture("gemini_400_api_key_invalid.json"))

      patch setup_path, params: { api_key: "AIzaSyPastedSecret12345" }

      expect(Nokogiri::HTML(response.body).at_css("#flash-alert").text).to start_with("Gemini didn't accept your API key")
      expect(user.reload).to be_on_trial
    end
  end

  it "has a response for every result the check can return" do
    AiService::KEY_CHECK_RESULTS.each do |result|
      allow_any_instance_of(ClaudeService).to receive(:check_key).and_return(result)

      patch setup_path, params: { api_key: "sk-ant-api03-PastedSecret" }

      expect(response.status).to be_in([ 302, 422 ])
    end
  end

  it "raises on a result it has no response for" do
    allow_any_instance_of(ClaudeService).to receive(:check_key).and_return(:surprised)

    expect { patch setup_path, params: { api_key: "sk-ant-api03-PastedSecret" } }.to raise_error(KeyError)
  end

  describe "the limit on saving keys" do
    before do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    it "stops checking keys for an account past its hourly allowance, and says so on the form" do
      requests = stub_key_check(ClaudeService, status: 401)

      (ApiKeysController::KEY_SAVES_PER_HOUR + 1).times { patch setup_path, params: { api_key: "sk-ant-api03-PastedSecret" } }

      expect(requests.size).to eq(ApiKeysController::KEY_SAVES_PER_HOUR)
      expect(response).to have_http_status(:too_many_requests)
      expect(Nokogiri::HTML(response.body).at_css("#flash-alert").text).to eq("You've saved a key several times in the last hour. Try again later.")
    end

    it "counts each account separately" do
      requests = stub_key_check(ClaudeService)
      ApiKeysController::KEY_SAVES_PER_HOUR.times { patch setup_path, params: { api_key: "sk-ant-api03-PastedSecret" } }

      other = User.create!(email: "other@example.com", track_chosen_at: Time.current)
      login_as(other)
      patch setup_path, params: { api_key: "sk-ant-api03-OtherSecret" }

      expect(response).to redirect_to(root_path)
      expect(requests.size).to eq(ApiKeysController::KEY_SAVES_PER_HOUR + 1)
    end

    it "stops one address past its own allowance, across accounts" do
      requests = stub_key_check(ClaudeService)
      accounts = (ApiKeysController::KEY_SAVES_PER_HOUR_BY_IP / ApiKeysController::KEY_SAVES_PER_HOUR) + 1

      accounts.times do |n|
        login_as(User.create!(email: "address-#{n}@example.com", track_chosen_at: Time.current))
        ApiKeysController::KEY_SAVES_PER_HOUR.times { patch setup_path, params: { api_key: "sk-ant-api03-PastedSecret" } }
      end

      expect(requests.size).to eq(ApiKeysController::KEY_SAVES_PER_HOUR_BY_IP)
      expect(response).to have_http_status(:too_many_requests)
    end

    it "never counts a preferences-only save" do
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-existing" })

      (ApiKeysController::KEY_SAVES_PER_HOUR + 1).times { patch setup_path, params: { api_key: "", language: "javascript" } }

      expect(response).to redirect_to(root_path)
    end

    it "sets the per-address allowance above the per-account one" do
      expect(ApiKeysController::KEY_SAVES_PER_HOUR_BY_IP).to be > ApiKeysController::KEY_SAVES_PER_HOUR
    end
  end
end
