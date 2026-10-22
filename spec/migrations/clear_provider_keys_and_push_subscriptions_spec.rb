require "rails_helper"
require Rails.root.join("db/migrate/20261021090000_clear_provider_keys_and_push_subscriptions").to_s

RSpec.describe ClearProviderKeysAndPushSubscriptions do
  def migrate_up = ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }

  let(:own_key) { User.create!(email: "own@example.com", name: "Own", provider: "gemini", api_keys: { "gemini" => "AIza-own" }) }
  let(:trial) do
    User.create!(email: "trial@example.com", name: "Trial", provider: "gemini", api_keys: { "gemini" => "AIza-trial" },
                 trial_started_at: 1.day.ago, trial_ends_at: 6.days.from_now, trial_consented_at: 1.day.ago)
  end

  it "clears every stored key and the provider it chose, without decrypting them" do
    own_key.update_column(:api_keys, "ciphertext the rotated keys cannot read")

    migrate_up

    expect(own_key.reload.read_attribute_before_type_cast(:api_keys)).to be_nil
    expect(own_key.provider).to be_nil
  end

  it "keeps a trial account's provider, which picks its house key once its own key is gone" do
    trial
    migrate_up

    expect(trial.reload.provider).to eq("gemini")
    expect(trial.read_attribute_before_type_cast(:api_keys)).to be_nil
  end

  it "deletes every push subscription, since the new VAPID keys cannot reach them" do
    own_key.push_subscriptions.create!(endpoint: "https://push.example/1", p256dh_key: "p", auth_key: "a")

    expect { migrate_up }.to change(PushSubscription, :count).to(0)
  end
end
