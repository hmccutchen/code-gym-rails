require "rails_helper"

RSpec.describe User, "counting generation failures the provider blamed on the account" do
  let(:user) { User.create!(email: "held@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "UTC") }

  def failures = user.reload.generation_account_failures

  def bad_key = ProviderError::AuthenticationError.new("invalid x-api-key")

  def out_of_credit = ProviderError::BillingError.new("credit balance is too low")

  describe "#record_generation_failure!" do
    it "raises the count by one for a rejected key" do
      user.record_generation_failure!(bad_key)

      expect(failures).to eq(1)
      expect(user.generation_account_failures).to eq(1)
    end

    it "raises the count by one for an account out of credit" do
      user.record_generation_failure!(out_of_credit)

      expect(failures).to eq(1)
    end

    it "reaches the hold with one of each" do
      user.record_generation_failure!(bad_key)
      user.record_generation_failure!(out_of_credit)

      expect(failures).to eq(KeyHold::AFTER)
    end

    it "adds to the stored count, though this copy was loaded before another failure was written" do
      stale = User.find(user.id)
      user.record_generation_failure!(bad_key)

      stale.record_generation_failure!(bad_key)

      expect(failures).to eq(2)
    end

    {
      "a short rate limit"   => -> { ProviderError::RateLimitError.new("slow down", http_status: 429) },
      "a daily limit"        => -> { ProviderError::RateLimitError.new("quota", http_status: 429, retry_after: 7200) },
      "an overloaded reply"  => -> { ProviderError::RateLimitError.new("overloaded", http_status: 529) },
      "an outage"            => -> { ProviderError.new("bad gateway", http_status: 502) },
      "a dropped connection" => -> { ProviderError::NetworkError.new("connection reset") },
      "a timeout"            => -> { ProviderError::TimeoutError.new("timed out") },
      "a setup problem"      => -> { SetupError.new("User has no recognized AI provider configured") },
      "any other failure"    => -> { ProviderError.new("boom") }
    }.each do |name, error|
      it "leaves the count alone for #{name}, whether it stands at zero or one" do
        user.record_generation_failure!(error.call)
        expect(failures).to eq(0)

        user.record_generation_failure!(bad_key)
        user.record_generation_failure!(error.call)

        expect(failures).to eq(1)
        expect(KeyHold::KINDS).not_to include(user.last_generation_failure)
      end
    end

    it "still records the failure itself as before" do
      user.record_generation_failure!(bad_key)

      expect(user.reload).to have_attributes(last_generation_failure: "bad_key", last_generation_error_date: Date.current)
    end
  end

  describe "#record_generation_message!" do
    it "leaves the count alone, since no provider blamed the account" do
      user.record_generation_failure!(bad_key)

      user.record_generation_message!("every section failed its check")

      expect(failures).to eq(1)
    end
  end

  describe "#clear_generation_failure!" do
    it "leaves the count alone, since pressing Try again proves nothing about the key" do
      2.times { user.record_generation_failure!(bad_key) }

      user.clear_generation_failure!

      expect(failures).to eq(2)
    end
  end

  describe "#record_generation_success!" do
    it "sets the count back to zero and clears today's failure" do
      2.times { user.record_generation_failure!(bad_key) }

      user.record_generation_success!

      expect(user.reload).to have_attributes(generation_account_failures: 0, last_generation_failure: nil,
                                             last_generation_error_date: nil)
    end

    it "resets the stored count, though this copy was loaded before the failures were written" do
      stale = User.find(user.id)
      2.times { user.record_generation_failure!(bad_key) }

      stale.record_generation_success!

      expect(failures).to eq(0)
    end

    it "writes nothing for an account with no failure and no count" do
      before_save = user.reload.updated_at

      travel(1.hour) { user.record_generation_success! }

      expect(user.reload.updated_at).to eq(before_save)
    end
  end

  describe "#store_api_key" do
    it "sets the count back to zero when the key is saved" do
      2.times { user.record_generation_failure!(bad_key) }
      user.reload

      user.store_api_key("sk-ant-api03-new", provider: "anthropic")
      user.save!

      expect(failures).to eq(0)
    end
  end

  describe "#use_provider" do
    before do
      user.update!(api_keys: user.api_keys.merge("openai" => "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq"))
      2.times { user.record_generation_failure!(bad_key) }
      user.reload
    end

    it "sets the count back to zero when the account switches to another stored key" do
      user.use_provider("openai")
      user.save!

      expect(user.reload).to have_attributes(provider: "openai", generation_account_failures: 0)
      expect(ScheduledGeneration.users).to include(user)
    end

    it "leaves the count alone when the provider named is the one already in use" do
      user.use_provider("anthropic")
      user.save!

      expect(failures).to eq(2)
    end
  end

  it "is separate from the pause: a held account has no pause time and no source" do
    2.times { user.record_generation_failure!(bad_key) }

    expect(user.reload).to have_attributes(paused_generation_at: nil, generation_pause_source: nil,
                                           generation_paused_automatically?: false)
  end
end
