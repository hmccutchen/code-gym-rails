require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261015120000_add_level_suggestion_columns_to_users.rb")
require migration_path.to_s

RSpec.describe AddLevelSuggestionColumnsToUsers do
  let(:connection) { ActiveRecord::Base.connection }

  after { User.reset_column_information }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    User.reset_column_information
  end

  def track_columns(user_id)
    connection.select_one("SELECT track_suggestions, track_evidence_cutoffs FROM users WHERE id = #{user_id}")
  end

  def write_track_columns(user, suggestions:, cutoffs:)
    connection.exec_update("UPDATE users SET track_suggestions = #{suggestions}, " \
                           "track_evidence_cutoffs = #{connection.quote(cutoffs.to_json)} WHERE id = #{user.id}")
  end

  it "copies each account's switch and cutoffs from the track columns" do
    off = User.create!(email: "off@example.com", name: "Off")
    on = User.create!(email: "on@example.com", name: "On")
    cutoffs = { "code_review" => { "level" => "junior", "through" => "2026-10-10" } }
    migrate(:down)
    write_track_columns(off, suggestions: false, cutoffs: cutoffs)

    migrate(:up)

    expect(off.reload).to have_attributes(level_suggestions: false, level_suggestion_cutoffs: cutoffs)
    expect(on.reload).to have_attributes(level_suggestions: true, level_suggestion_cutoffs: {})
  end

  it "gives an account created afterwards the defaults" do
    user = User.create!(email: "new@example.com", name: "New")

    expect(user.reload).to have_attributes(level_suggestions: true, level_suggestion_cutoffs: {})
  end

  it "rolls back by removing the new columns and leaving the track columns as they were" do
    user = User.create!(email: "kept@example.com", name: "Kept")
    write_track_columns(user, suggestions: false, cutoffs: { "pattern" => { "level" => "senior" } })

    migrate(:down)

    expect(connection.column_exists?(:users, :level_suggestions)).to be(false)
    expect(connection.column_exists?(:users, :level_suggestion_cutoffs)).to be(false)
    expect(track_columns(user.id)).to eq("track_suggestions" => false,
                                          "track_evidence_cutoffs" => '{"pattern": {"level": "senior"}}')
  ensure
    migrate(:up)
  end

  it "keeps the track columns out of User for one release" do
    expect(User.column_names).not_to include("track_suggestions", "track_evidence_cutoffs")
    expect(connection.column_exists?(:users, :track_suggestions)).to be(true)
  end
end
