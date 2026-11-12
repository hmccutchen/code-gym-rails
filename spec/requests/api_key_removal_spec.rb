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

    it "sets the key-hold count back to zero" do
      user.update!(generation_account_failures: KeyHold::AFTER)
      login_as(user)

      delete setup_key_path("openai")

      expect(user.reload.generation_account_failures).to eq(0)
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
end
