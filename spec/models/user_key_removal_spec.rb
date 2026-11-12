require "rails_helper"

RSpec.describe User, "removing a stored key" do
  let(:keys) { { "anthropic" => "sk-ant-one", "gemini" => "AIzaTwo", "openai" => "sk-proj-three" } }
  let(:user) { User.create!(email: "keys@example.com", provider: "anthropic", api_keys: keys, time_zone: "UTC") }

  def bad_key = ProviderError::AuthenticationError.new("invalid x-api-key")

  describe "#store_api_key" do
    it "records when each provider's key was saved, as an ISO 8601 time" do
      fresh = User.create!(email: "fresh@example.com")

      travel_to(Time.utc(2026, 11, 12, 9, 30)) { fresh.store_api_key("sk-ant-one", provider: "anthropic") }
      travel_to(Time.utc(2026, 11, 12, 10, 45)) { fresh.store_api_key("sk-proj-two", provider: "openai") }
      fresh.save!

      saved = fresh.reload.key_saved_times
      expect(saved.keys).to contain_exactly("anthropic", "openai")
      expect(Time.iso8601(saved["anthropic"])).to eq(Time.utc(2026, 11, 12, 9, 30))
      expect(Time.iso8601(saved["openai"])).to eq(Time.utc(2026, 11, 12, 10, 45))
    end

    it "moves a provider's time forward when its key is replaced, and leaves the others" do
      travel_to(Time.utc(2026, 11, 1)) { user.store_api_key("AIzaOld", provider: "gemini") }
      travel_to(Time.utc(2026, 11, 2)) { user.store_api_key("sk-ant-old", provider: "anthropic") }
      travel_to(Time.utc(2026, 11, 5)) { user.store_api_key("AIzaNew", provider: "gemini") }
      user.save!

      saved = user.reload.key_saved_times
      expect(Time.iso8601(saved["gemini"])).to eq(Time.utc(2026, 11, 5))
      expect(Time.iso8601(saved["anthropic"])).to eq(Time.utc(2026, 11, 2))
    end
  end

  describe "#remove_api_key" do
    it "deletes the provider's key and its save time, and keeps the others" do
      user.update!(key_saved_times: { "anthropic" => "2026-11-01T00:00:00Z", "gemini" => "2026-11-02T00:00:00Z" })

      expect(user.remove_api_key("gemini")).to eq(:removed)
      user.save!

      user.reload
      expect(user.api_keys).to eq(keys.except("gemini"))
      expect(user.key_saved_times).to eq("anthropic" => "2026-11-01T00:00:00Z")
    end

    it "drops a save time left behind for a provider with no stored key" do
      user.update!(api_keys: keys.slice("anthropic", "gemini"), key_saved_times: { "openai" => "2026-11-02T00:00:00Z" })

      user.remove_api_key("gemini")

      expect(user.key_saved_times).to eq({})
    end

    it "leaves the provider in use alone when another provider's key is removed" do
      user.remove_api_key("openai")
      user.save!

      expect(user.reload).to have_attributes(provider: "anthropic", api_key: "sk-ant-one")
    end

    it "switches to the most recently saved key that remains when the key in use is removed" do
      user.update!(key_saved_times: { "anthropic" => "2026-11-09T00:00:00Z", "gemini" => "2026-11-03T00:00:00Z",
                                   "openai" => "2026-11-07T00:00:00Z" })

      expect(user.remove_api_key("anthropic")).to eq(:switched)
      user.save!

      expect(user.reload).to have_attributes(provider: "openai", api_key: "sk-proj-three")
    end

    it "compares save times as times, whatever offset each was written with" do
      user.update!(key_saved_times: { "gemini" => "2026-11-07T09:00:00+09:00", "openai" => "2026-11-07T01:00:00Z" })

      user.remove_api_key("anthropic")

      expect(user.provider).to eq("openai")
    end

    it "ranks a key with no recorded save time behind every key that has one" do
      user.update!(key_saved_times: { "openai" => "2020-01-01T00:00:00Z" })

      user.remove_api_key("anthropic")

      expect(user.provider).to eq("openai")
    end

    it "ranks a key whose recorded time cannot be read as one with none" do
      user.update!(key_saved_times: { "gemini" => "yesterday", "openai" => "2020-01-01T00:00:00Z" })

      user.remove_api_key("anthropic")

      expect(user.provider).to eq("openai")
    end

    it "breaks a tie in the provider registry's order" do
      user.update!(key_saved_times: { "gemini" => "2026-11-07T00:00:00Z", "openai" => "2026-11-07T00:00:00Z" })
      user.remove_api_key("anthropic")
      expect(user.provider).to eq((AiProvider.keys & %w[gemini openai]).first)

      untimed = User.create!(email: "untimed@example.com", provider: "openai", api_keys: keys)
      untimed.remove_api_key("openai")
      expect(untimed.provider).to eq((AiProvider.keys & %w[anthropic gemini]).first)
    end

    it "leaves no keys, no save times and no provider in use when the last key is removed" do
      user.update!(api_keys: { "anthropic" => "sk-ant-one" }, key_saved_times: { "anthropic" => "2026-11-01T00:00:00Z" })

      expect(user.remove_api_key("anthropic")).to eq(:last_removed)
      user.save!

      user.reload
      expect(user.api_keys).to be_nil
      expect(user.key_saved_times).to eq({})
      expect(user.provider).to be_nil
      expect(user.api_key_present?).to be(false)
      expect(User.where(api_keys: nil)).to include(user)
    end

    it "takes an account with no key left out of scheduled generation" do
      user.update!(api_keys: { "anthropic" => "sk-ant-one" })
      expect(ScheduledGeneration.users).to include(user)

      user.remove_api_key("anthropic")
      user.save!

      expect(ScheduledGeneration.users).not_to include(user)
    end

    it "sets the key-hold count back to zero, whichever key is removed" do
      2.times { user.record_generation_failure!(bad_key) }
      user.reload

      user.remove_api_key("openai")
      user.save!

      expect(user.reload.generation_account_failures).to eq(0)
      expect(ScheduledGeneration.users).to include(user)
    end

    it "changes nothing for a provider with no stored key, an unknown provider or no name" do
      user.update!(api_keys: keys.except("openai"))

      [ "openai", "mistral", "", nil ].each do |name|
        expect(user.remove_api_key(name)).to eq(:not_stored)
        expect(user.changed?).to be(false)
      end
    end

    it "changes nothing for an account with no keys" do
      keyless = User.create!(email: "keyless@example.com")

      expect(keyless.remove_api_key("anthropic")).to eq(:not_stored)
      expect(keyless.changed?).to be(false)
    end

    it "counts an account with an unfinished trial as on trial again once its key is gone" do
      user.update!(api_keys: { "anthropic" => "sk-ant-one" }, trial_started_at: 1.day.ago, trial_ends_at: 5.days.from_now)
      expect(user.on_trial?).to be(false)

      user.remove_api_key("anthropic")
      user.save!

      expect(user.reload.on_trial?).to be(true)
    end
  end

  describe "#key_removal_outcome" do
    it "names what removing each key would do without changing the account" do
      user.update!(key_saved_times: { "gemini" => "2026-11-07T00:00:00Z" })

      expect(user.key_removal_outcome("anthropic")).to eq(:switched)
      expect(user.key_removal_outcome("gemini")).to eq(:removed)
      expect(user.key_removal_outcome("fake")).to eq(:not_stored)
      expect(user.provider_after_removing("anthropic")).to eq("gemini")
      expect(user.provider_after_removing("gemini")).to eq("anthropic")
      expect(user.changed?).to be(false)
    end
  end

  describe "#anonymize!" do
    it "clears the save times with the keys" do
      user.update!(key_saved_times: { "anthropic" => "2026-11-01T00:00:00Z" })

      user.anonymize!

      expect(user.reload).to have_attributes(api_keys: nil, key_saved_times: {})
    end
  end
end
