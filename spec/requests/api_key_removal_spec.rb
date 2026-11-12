require "rails_helper"

RSpec.describe "Removing a stored key on Setup", type: :request do
  let(:keys) { { "anthropic" => "sk-ant-api03-one", "openai" => "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq" } }
  let(:user) do
    User.create!(email: "dev@example.com", track_chosen_at: Time.current, provider: "anthropic", api_keys: keys,
                 key_saved_times: { "anthropic" => "2026-11-01T00:00:00Z", "openai" => "2026-11-02T00:00:00Z" })
  end

  def page_text = Nokogiri::HTML(response.body).text.squish

  describe "GET /setup" do
    it "lists each stored provider with a named Remove button, marks the one in use and shows no key" do
      login_as(user)

      get setup_path

      list = Nokogiri::HTML(response.body).at_css("#saved-keys")
      expect(list.css("li").map { |item| item.at_css(".saved-key-name").text.squish }).to eq(%w[Claude GPT])
      expect(list.css("li").map { |item| item.at_css(".card-tag")&.text&.squish }).to eq([ "In use", nil ])
      expect(list.css("button").map { |button| button.text.squish }).to eq([ "Remove Claude key", "Remove GPT key" ])
      expect(list.css("form").map { |form| form["action"] }).to eq([ setup_key_path("anthropic"), setup_key_path("openai") ])
      expect(list.css("input[name=_method]").map { |input| input["value"] }.uniq).to eq([ "delete" ])
      keys.each_value { |key| expect(response.body).not_to include(key) }
    end

    it "asks for confirmation in words that say what removing each key does" do
      login_as(user)

      get setup_path

      messages = Nokogiri::HTML(response.body).css("#saved-keys form").map { |form| form["data-loading-form-confirm-message-value"] }
      expect(messages).to eq([ "Remove your Claude key? Coding Gym will switch to your GPT key.",
                               "Remove your GPT key? You can add it again later." ])
    end

    it "warns that sets stop when the key is the only one" do
      user.update!(api_keys: keys.slice("anthropic"))
      login_as(user)

      get setup_path

      form = Nokogiri::HTML(response.body).at_css("#saved-keys form")
      expect(form["data-loading-form-confirm-message-value"]).to eq("Remove your Claude key? It is your only key, so new sets stop until you add one.")
    end

    it "shows no list for an account with no stored key" do
      keyless = User.create!(email: "keyless@example.com", track_chosen_at: Time.current)
      login_as(keyless)

      get setup_path

      expect(response.body).not_to include("saved-keys")
    end
  end

  describe "DELETE /setup/keys/:provider" do
    it "removes a key that is not in use and says so" do
      login_as(user)

      delete setup_key_path("openai")

      expect(response).to redirect_to(setup_path)
      expect(flash[:notice]).to eq("Your GPT key was removed.")
      expect(user.reload).to have_attributes(provider: "anthropic", api_keys: keys.slice("anthropic"),
                                             key_saved_times: { "anthropic" => "2026-11-01T00:00:00Z" })
    end

    it "removes the key in use, switches to the one that remains and names it" do
      login_as(user)

      delete setup_key_path("anthropic")

      expect(response).to redirect_to(setup_path)
      expect(flash[:notice]).to eq("Your Claude key was removed. GPT is now the provider in use.")
      expect(user.reload).to have_attributes(provider: "openai", api_key: keys["openai"])
      follow_redirect!
      expect(page_text).to include("Your Claude key was removed. GPT is now the provider in use.")
    end

    it "removes the last key, says sets stop, and sends every other page back to Setup" do
      user.update!(api_keys: keys.slice("anthropic"))
      login_as(user)

      delete setup_key_path("anthropic")

      expect(response).to redirect_to(setup_path)
      expect(flash[:notice]).to eq("Your Claude key was removed. New sets stop until you add a key.")
      expect(user.reload).to have_attributes(provider: nil, api_keys: nil, key_saved_times: {})
      follow_redirect!
      expect(response).to have_http_status(:ok)
      [ root_path, history_path, learn_path, progress_path ].each do |path|
        get path
        expect(response).to redirect_to(setup_path)
      end
      get account_path
      expect(response).to have_http_status(:ok)
    end

    it "sets the key-hold count back to zero when the key in use is removed, and leaves it for any other key" do
      user.update!(generation_account_failures: KeyHold::AFTER)
      login_as(user)

      delete setup_key_path("openai")
      expect(user.reload.generation_account_failures).to eq(KeyHold::AFTER)

      delete setup_key_path("anthropic")
      expect(user.reload.generation_account_failures).to eq(0)
    end

    it "takes the removed key's failure off the dashboard once the app has switched keys" do
      user.record_generation_failure!(ProviderError::AuthenticationError.new("invalid x-api-key"))
      login_as(user)
      get root_path
      expect(page_text).to include("Claude didn't accept your API key")

      delete setup_key_path("anthropic")
      get root_path

      expect(page_text).not_to include("didn't accept your API key")
    end

    it "refuses a provider with no stored key, an unknown one and the fake one, and changes nothing" do
      login_as(user)
      user.update!(api_keys: keys.slice("anthropic"))

      %w[openai mistral fake].each do |name|
        delete setup_key_path(name)

        expect(response).to redirect_to(setup_path)
        expect(flash[:alert]).to eq("There is no saved key for that provider, so nothing was removed.")
      end
      expect(user.reload).to have_attributes(provider: "anthropic", api_keys: keys.slice("anthropic"))
    end

    it "removes from the keys as they are stored now, so a key saved in another tab stays" do
      login_as(user)
      get setup_path
      User.find(user.id).tap { |other_tab| other_tab.store_api_key("AIzaSyExampleKey12345", provider: "gemini") }.save!

      delete setup_key_path("gemini")

      expect(user.reload).to have_attributes(provider: "openai", api_keys: keys)
    end

    it "writes nothing for an account deleted in another browser, and sends this one to sign in" do
      login_as(user)
      allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        User.find(original.receiver.id).update_columns(anonymized_at: Time.current, api_keys: nil)
        original.call(*args, &block)
      end

      delete setup_key_path("anthropic")

      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to eq(I18n.t("flash.application.login_required"))
      expect(user.reload.provider).to eq("anthropic")
    end

    it "asks a signed-out browser to sign in" do
      delete setup_key_path("anthropic")

      expect(response).to redirect_to(login_path)
      expect(user.reload.api_keys).to eq(keys)
    end

    it "calls no provider and is not counted against the key-save limit" do
      login_as(user)
      expect(AiService).not_to receive(:check_key)

      (ApiKeysController::KEY_SAVES_PER_HOUR + 1).times { delete setup_key_path("mistral") }

      expect(response).to redirect_to(setup_path)
    end
  end

  describe "PATCH /setup with a key, after a failure today" do
    include ActiveJob::TestHelper

    around { |example| travel_to(Time.utc(2026, 7, 13, 13, 0)) { example.run } }

    def fail_on_claude
      user.record_generation_failure!(ProviderError::AuthenticationError.new("invalid x-api-key"))
      login_as(user)
      get root_path
      expect(page_text).to include("Claude didn't accept your API key")
    end

    { "a checked save" => {}, "a save without checking" => { skip_check: ApiKeysController::SKIP_CHECK } }.each do |name, extra|
      it "starts a set after #{name} of a new key for the provider that failed" do
        fail_on_claude

        patch setup_path, params: { api_key: "sk-ant-api03-working", **extra }
        follow_redirect!

        expect(page_text).to include("Generating your personalized exercise set")
        expect(page_text).not_to include("didn't accept your API key")
        expect(user.reload).to have_attributes(generation_failed_today?: false, api_key: "sk-ant-api03-working")
      end

      it "starts a set after #{name} of a key for another provider, which takes over" do
        fail_on_claude

        patch setup_path, params: { api_key: "AIzaSyExampleKey12345", **extra }
        follow_redirect!

        expect(page_text).to include("Generating your personalized exercise set")
        expect(user.reload).to have_attributes(provider: "gemini", generation_failed_today?: false)
      end
    end

    it "keeps the failure when the key is rejected and nothing is saved" do
      fail_on_claude
      allow_any_instance_of(AiService).to receive(:check_key).and_return(:rejected)

      patch setup_path, params: { api_key: "sk-ant-api03-wrong" }

      expect(user.reload).to have_attributes(generation_failed_today?: true, last_generation_failure: "bad_key")
    end
  end

  describe "GET /dashboard/status after a call outlived its key" do
    around { |example| travel_to(Time.utc(2026, 7, 13, 13, 0)) { example.run } }

    def provider_raising_after(error)
      service = instance_double(ClaudeService)
      allow(service).to receive(:generate_judged_exercise) do |*|
        yield
        raise error
      end
      allow(AiService).to receive(:for).and_return(service)
      allow(Rails.logger).to receive(:error)
    end

    it "answers failed with the neutral message, so the waiting page stops polling" do
      login_as(user)
      provider_raising_after(ProviderError::AuthenticationError.new("invalid x-api-key")) { delete setup_key_path("anthropic") }

      GenerateDailyExercisesJob.new.perform(user_id: user.id)
      get dashboard_status_path

      expect(JSON.parse(response.body)).to eq("status" => "failed", "message" => GenerateDailyExercisesJob::SUPERSEDED_MESSAGE)
    end

    it "answers ready after a regeneration that outlived its key releases its claim, having recorded nothing" do
      login_as(user)
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago, language: "ruby_rails",
                            problem_set: { "code_review" => { "question" => "old" } }, regenerating_since: Time.current)
      provider_raising_after(ProviderError::AuthenticationError.new("invalid x-api-key")) { delete setup_key_path("anthropic") }

      RegenerateExerciseJob.new.perform(user_id: user.id)
      get dashboard_status_path

      expect(JSON.parse(response.body)).to eq("status" => "ready")
      expect(user.reload.generation_failed_today?).to be(false)
    end
  end

  describe "what each removal outcome says" do
    it "has a message for every outcome the model can return, and a confirmation for each that removes a key" do
      expect(ApiKeysController::KEY_REMOVAL_MESSAGES.keys).to match_array(User::KEY_REMOVAL_OUTCOMES)
      ApiKeysController::KEY_REMOVAL_MESSAGES.each_value { |key| expect(I18n.exists?(key)).to be(true), "no text at #{key}" }
      (User::KEY_REMOVAL_OUTCOMES - [ :not_stored ]).each do |outcome|
        expect(I18n.exists?("api_keys.edit.saved_keys.confirm.#{outcome}")).to be(true), "no confirmation for #{outcome}"
      end
    end
  end

  describe "PATCH /setup with a provider choice" do
    def remove_in_another_tab(name)
      allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        User.find(original.receiver.id).tap { |other_tab| other_tab.remove_api_key(name) }.save!
        original.call(*args, &block)
      end
    end

    it "refuses a provider whose key was removed in another tab after this page loaded, and saves nothing" do
      login_as(user)
      remove_in_another_tab("openai")

      patch setup_path, params: { api_key: "", provider: "openai", language: "javascript" }

      expect(response).to redirect_to(setup_path)
      expect(flash[:alert]).to eq("That provider has no saved key, so nothing was changed.")
      expect(user.reload).to have_attributes(provider: "anthropic", api_keys: keys.slice("anthropic"), language: "ruby_rails")
    end

    it "writes nothing for an account deleted in another browser, with no provider posted, and sends this one to sign in" do
      login_as(user)
      allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        User.find(original.receiver.id).update_columns(anonymized_at: Time.current, api_keys: nil)
        original.call(*args, &block)
      end

      patch setup_path, params: { api_key: "", language: "javascript" }

      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to eq(I18n.t("flash.application.login_required"))
      expect(flash[:notice]).not_to eq(I18n.t("flash.api_keys.preferences_saved"))
      expect(user.reload.language).to eq("ruby_rails")
    end

    it "still switches to a provider whose key is stored" do
      login_as(user)

      patch setup_path, params: { api_key: "", provider: "openai" }

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq(I18n.t("flash.api_keys.preferences_saved"))
      expect(user.reload.provider).to eq("openai")
    end
  end
end
