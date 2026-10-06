require "rails_helper"

RSpec.describe ProviderCredential, type: :model do
  it "hands an own-key account its stored key, never a house key" do
    user = create_user_with_key
    stub_env("HOUSE_ANTHROPIC_API_KEY" => "sk-ant-house")

    credential = described_class.for(user)

    expect(credential.key).to eq("sk-ant-test-key")
    expect(credential.house).to be(false)
  end

  it "hands an account with neither key nor trial nothing, as before trials existed" do
    user = User.create!(email: "bare@example.com", name: "Bare")

    expect(described_class.for(user)).to eq(described_class::Credential.new(key: nil, house: false))
  end

  it "hands an active trial the house key for its provider, read from ENV at call time" do
    user = create_trial_user(provider: "fake", house_key: "fake-house-key")

    credential = described_class.for(user)

    expect(credential).to eq(described_class::Credential.new(key: "fake-house-key", house: true))
    expect(user.api_keys).to be_nil
    expect(user.provider).to eq("fake")
  end

  it "raises TrialEndedError once the trial has ended, under the kill switch, or with no house key set" do
    user = create_trial_user(provider: "fake")

    travel_to(user.trial_ends_at + 1.minute) do
      expect { described_class.for(user) }.to raise_error(AiService::TrialEndedError)
      expect(user).to be_trial_ended
    end

    stub_env("TRIALS_DISABLED" => "1")
    expect { described_class.for(user) }.to raise_error(AiService::TrialEndedError)
    expect(TrialMode.enabled?).to be(false)

    stub_env("TRIALS_DISABLED" => nil, "HOUSE_FAKE_API_KEY" => nil)
    expect { described_class.for(user) }.to raise_error(AiService::TrialEndedError)
  end

  it "prefers a key the trial account pasted over the house key" do
    user = create_trial_user(provider: "fake")
    user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-own" })

    expect(described_class.for(user)).to eq(described_class::Credential.new(key: "sk-ant-own", house: false))
  end

  it "reads the guard from ENV as an integer, or nothing" do
    stub_env("HOUSE_GEMINI_DAILY_GUARD" => "16", "HOUSE_ANTHROPIC_DAILY_GUARD" => "lots")

    expect(HouseKeys.daily_guard_for("gemini")).to eq(16)
    expect(HouseKeys.daily_guard_for("anthropic")).to be_nil
    expect(HouseKeys.daily_guard_for("openai")).to be_nil
  end
end
