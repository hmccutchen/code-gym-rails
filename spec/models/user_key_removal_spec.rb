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

  describe "#store_api_key and a failure recorded earlier" do
    def rate_limited_on(provider) = ProviderError::RateLimitError.new("slow down", http_status: 429).tap { |e| e.provider = provider }

    it "clears a failure recorded against the provider whose key is saved, in the same save" do
      user.record_generation_failure!(bad_key)
      user.reload

      user.store_api_key("sk-ant-working", provider: "anthropic")
      expect(User.find(user.id).generation_failed_today?).to be(true)
      user.save!

      expect(user.reload).to have_attributes(generation_failed_today?: false, last_generation_failure: nil,
                                             last_generation_failure_provider: nil, last_generation_failed_at: nil)
    end

    it "clears a failure recorded against the provider the save switches away from" do
      user.record_generation_failure!(bad_key)
      user.reload

      user.store_api_key("sk-proj-working", provider: "openai")
      user.save!

      expect(user.reload).to have_attributes(provider: "openai", generation_failed_today?: false, last_generation_failure: nil)
    end

    it "keeps a failure recorded against a provider that is neither saved nor the one the save switches away from" do
      user.record_generation_failure!(rate_limited_on("gemini"))
      user.reload

      user.store_api_key("sk-proj-working", provider: "openai")
      user.save!

      expect(user.reload).to have_attributes(generation_failed_today?: true, last_generation_failure_provider: "gemini")
    end

    it "keeps a message that names no provider" do
      user.record_generation_message!("Settings or another set changed while this set was being prepared.")
      user.reload

      user.store_api_key("sk-ant-working", provider: "anthropic")
      user.save!

      expect(user.reload.last_generation_error).to eq("Settings or another set changed while this set was being prepared.")
    end

    it "clears nothing on a first key for an account with a provider-less message and no provider" do
      fresh = User.create!(email: "fresh-message@example.com")
      fresh.record_generation_message!("left earlier")

      fresh.store_api_key("sk-ant-one", provider: "anthropic")
      fresh.save!

      expect(fresh.reload.last_generation_error).to eq("left earlier")
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

    it "leaves the key-hold count and the hold alone when the key removed is not the one in use" do
      2.times { user.record_generation_failure!(bad_key) }
      user.reload

      user.remove_api_key("openai")
      user.save!

      expect(user.reload.generation_account_failures).to eq(KeyHold::AFTER)
      expect(ScheduledGeneration.users).not_to include(user)
    end

    it "sets the key-hold count back to zero when the key in use is removed and another takes over" do
      2.times { user.record_generation_failure!(bad_key) }
      user.reload

      user.remove_api_key("anthropic")
      user.save!

      expect(user.reload.generation_account_failures).to eq(0)
      expect(ScheduledGeneration.users).to include(user)
    end

    it "sets the key-hold count back to zero when the last key is removed" do
      user.update!(api_keys: { "anthropic" => "sk-ant-one" })
      2.times { user.record_generation_failure!(bad_key) }
      user.reload

      user.remove_api_key("anthropic")
      user.save!

      expect(user.reload.generation_account_failures).to eq(0)
    end

    it "clears a generation failure recorded against the removed provider, in the same save" do
      user.record_generation_failure!(bad_key)
      user.reload
      expect(user).to have_attributes(generation_failed_today?: true, last_generation_failure_provider: "anthropic")

      user.remove_api_key("anthropic")
      expect(User.find(user.id).generation_failed_today?).to be(true)
      user.save!

      expect(user.reload).to have_attributes(generation_failed_today?: false, last_generation_error_date: nil,
                                             last_generation_failure: nil, last_generation_failure_provider: nil,
                                             last_generation_failed_at: nil, last_generation_retry_after: nil)
    end

    it "keeps a generation failure recorded against another provider" do
      user.record_generation_failure!(bad_key)
      user.reload

      user.remove_api_key("openai")
      user.save!

      expect(user.reload).to have_attributes(generation_failed_today?: true, last_generation_failure: "bad_key",
                                             last_generation_failure_provider: "anthropic")
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

  describe "#report_call_failure" do
    it "runs the block while the account still uses the provider and key the call started with" do
      key_used = user.key_in_use

      user.report_call_failure(key_used) { user.record_generation_failure!(bad_key) }

      expect(user.reload).to have_attributes(generation_failed_today?: true, last_generation_failure: "bad_key")
    end

    it "skips the block once the key was removed, replaced or switched, and clears the call's own provider's failure" do
      changes = [ ->(account) { account.store_api_key("sk-ant-new", provider: "anthropic") },
                  ->(account) { account.use_provider("openai") } ]
      changes.each do |change|
        account = User.create!(email: "#{SecureRandom.hex(4)}@example.com", provider: "anthropic", api_keys: keys)
        key_used = account.key_in_use
        account.record_generation_failure!(bad_key)
        change.call(account)
        account.save!

        account.report_call_failure(key_used) { raise "the block ran" }

        expect(account.reload.generation_failed_today?).to be(false)
      end
    end

    it "leaves a failure a newer attempt recorded against another provider, with its recovery text" do
      user.update!(key_saved_times: { "openai" => "2026-11-07T00:00:00Z" })
      key_used = user.key_in_use
      user.remove_api_key("anthropic")
      user.save!
      user.record_generation_failure!(bad_key)
      expect(user.last_generation_failure_provider).to eq("openai")

      user.report_call_failure(key_used) { raise "the block ran" }

      expect(user.reload).to have_attributes(generation_failed_today?: true, last_generation_failure: "bad_key",
                                             last_generation_failure_provider: "openai")
      expect(user.generation_failure_message(surface: :generation)).to include("GPT didn't accept your API key")
    end

    it "leaves a message that names no provider, since nothing ties it to the call" do
      key_used = user.key_in_use
      user.use_provider("openai")
      user.save!
      user.record_generation_message!("Settings or another set changed while this set was being prepared.")

      user.report_call_failure(key_used) { raise "the block ran" }

      expect(user.reload.last_generation_error).to eq("Settings or another set changed while this set was being prepared.")
    end

    describe "given what to do when the key changed" do
      let(:neutral) { "Settings or another set changed." }

      def report(account, key_used) = account.report_call_failure(key_used, when_key_changed: -> { account.record_generation_message!(neutral) }) { raise "the block ran" }

      before { user.update!(key_saved_times: { "openai" => "2026-11-07T00:00:00Z" }) }

      it "does it when no failure is recorded today, and when today's failure is the call's own provider's" do
        key_used = user.key_in_use
        user.use_provider("openai")
        user.save!
        report(user, key_used)
        expect(user.reload).to have_attributes(last_generation_error: neutral, last_generation_failure_provider: nil)

        user.record_generation_failure!(ProviderError::AuthenticationError.new("bad").tap { |e| e.provider = "anthropic" })
        report(user, key_used)
        expect(user.reload).to have_attributes(last_generation_error: neutral, last_generation_failure: nil)
      end

      it "leaves a failure recorded today against another provider, and records nothing" do
        key_used = user.key_in_use
        user.use_provider("openai")
        user.save!
        user.record_generation_failure!(bad_key)

        report(user, key_used)

        expect(user.reload).to have_attributes(last_generation_failure: "bad_key", last_generation_failure_provider: "openai",
                                               last_generation_error: nil)
      end

      it "leaves a message recorded today that names no provider" do
        key_used = user.key_in_use
        user.use_provider("openai")
        user.save!
        user.record_generation_message!("An earlier message.")

        report(user, key_used)

        expect(user.reload.last_generation_error).to eq("An earlier message.")
      end

      it "records nothing once the account has no provider in use, since no dashboard can be waiting" do
        user.update!(api_keys: keys.slice("anthropic"))
        key_used = user.key_in_use
        user.remove_api_key("anthropic")
        user.save!

        report(user, key_used)

        expect(user.reload.generation_failed_today?).to be(false)
      end

      it "runs the block, not the fallback, while the key is unchanged" do
        ran = []
        user.report_call_failure(user.key_in_use, when_key_changed: -> { ran << :changed }) { ran << :same }

        expect(ran).to eq([ :same ])
      end
    end

    it "records nothing for a call that started with no provider, and clears nothing" do
      keyless = User.create!(email: "keyless@example.com")
      key_used = keyless.key_in_use
      expect(key_used).to eq([ nil, nil ])

      keyless.report_call_failure(key_used) { raise "the block ran" }

      expect(keyless.reload.generation_failed_today?).to be(false)
    end

    it "still records a failure for a trial account, which has a provider and no key of its own" do
      trial = User.create!(email: "trial@example.com", provider: "anthropic", trial_started_at: 1.day.ago, trial_ends_at: 5.days.from_now)
      key_used = trial.key_in_use
      expect(key_used).to eq([ "anthropic", nil ])

      trial.report_call_failure(key_used) { trial.record_generation_failure!(bad_key) }

      expect(trial.reload).to have_attributes(generation_failed_today?: true, last_generation_failure: "bad_key")
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
