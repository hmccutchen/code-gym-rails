require "rails_helper"

migration_path = Rails.root.join("db/migrate/20260712020000_backfill_user_provider.rb")
require migration_path.to_s

RSpec.describe BackfillUserProvider do
  it "backfills provider from an Anthropic-shaped key" do
    user = User.create!(email: "legacy@example.com", name: "Legacy")
    user.update!(api_key: "sk-ant-legacy-key")

    described_class.new.up

    expect(user.reload.provider).to eq("anthropic")
  end

  it "backfills provider from a Gemini-shaped key" do
    user = User.create!(email: "legacy-gemini@example.com", name: "Legacy Gemini")
    user.update!(api_key: "AIzaSyLegacyKey123")

    described_class.new.up

    expect(user.reload.provider).to eq("gemini")
  end

  it "leaves provider nil and logs a warning for an unrecognized key" do
    user = User.create!(email: "legacy-unknown@example.com", name: "Legacy Unknown")
    user.update!(api_key: "totally-unknown-format")

    expect(Rails.logger).to receive(:warn).with(/unrecognized key format/)
    described_class.new.up

    expect(user.reload.provider).to be_nil
  end

  it "skips users with no api_key set" do
    user = User.create!(email: "no-key@example.com", name: "No Key")

    expect { described_class.new.up }.not_to raise_error
    expect(user.reload.provider).to be_nil
  end

  it "is idempotent and does not re-update users with provider already set" do
    user = User.create!(email: "already-set@example.com", name: "Already Set")
    user.update!(api_key: "sk-ant-some-key", provider: "anthropic")

    # Should not raise or re-decrypt
    expect { described_class.new.up }.not_to raise_error
    expect(user.reload.provider).to eq("anthropic")
  end
end

