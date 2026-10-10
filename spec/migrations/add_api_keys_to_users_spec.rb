require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261002170000_add_api_keys_to_users.rb")
require migration_path.to_s

RSpec.describe AddApiKeysToUsers do
  let(:legacy_user) { described_class::LegacyUser }

  # Rolls the column back and forward so the backfill runs against rows with only the old column filled in.
  def rerun_migration
    ActiveRecord::Migration.suppress_messages do
      described_class.new.migrate(:down)
      legacy_user.reset_column_information
      yield if block_given?
      described_class.new.migrate(:up)
    end
  ensure
    [ legacy_user, User ].each(&:reset_column_information)
  end

  def legacy(email, api_key:, provider:)
    legacy_user.create!(email: email, name: "Legacy", api_key: api_key, provider: provider)
  end

  it "moves each stored key under its provider and keeps it encrypted" do
    user_ids = nil
    rerun_migration do
      user_ids = [ legacy("claude@example.com", api_key: "sk-ant-legacy", provider: "anthropic").id,
                   legacy("gpt@example.com", api_key: "sk-proj-legacy", provider: "openai").id ]
    end

    claude, gpt = User.find(user_ids)
    expect(claude.api_keys).to eq("anthropic" => "sk-ant-legacy")
    expect(claude.api_key).to eq("sk-ant-legacy")
    expect(gpt.api_keys).to eq("openai" => "sk-proj-legacy")
    raw = ActiveRecord::Base.connection.select_value("SELECT api_keys FROM users WHERE id = #{claude.id}")
    expect(raw).not_to include("sk-ant-legacy")
  end

  it "detects the provider when an old row stored a key without one" do
    user_id = nil
    rerun_migration { user_id = legacy("unset@example.com", api_key: "AIzaSyLegacy", provider: nil).id }

    user = User.find(user_id)
    expect(user.provider).to eq("gemini")
    expect(user.api_keys).to eq("gemini" => "AIzaSyLegacy")
  end

  it "leaves an unrecognized key out and a keyless account without keys" do
    ids = nil
    rerun_migration do
      ids = [ legacy("odd@example.com", api_key: "not-a-known-format", provider: nil).id,
              legacy("none@example.com", api_key: nil, provider: nil).id ]
    end

    expect(User.find(ids).map(&:api_keys)).to eq([ nil, nil ])
  end
end
