require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261014170000_add_level_suggestion_columns_to_users.rb")
require migration_path.to_s

RSpec.describe AddLevelSuggestionColumnsToUsers do
  let(:connection) { ActiveRecord::Base.connection }
  let(:cutoffs) { { "code_review" => { "level" => "junior", "through" => "2026-10-10" } } }

  after { User.reset_column_information }

  def account(email)
    User.create!(email: email, name: "Account")
  end

  def write_track_columns(user, suggestions:, cutoffs:)
    connection.exec_update("UPDATE users SET track_suggestions = $1, track_evidence_cutoffs = $2 WHERE id = $3",
                           "track columns", [ suggestions, cutoffs.to_json, user.id ])
  end

  def column_values(user, *columns)
    connection.select_one("SELECT #{columns.join(', ')} FROM users WHERE id = #{user.id}")
  end

  def run(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    User.reset_column_information
  end

  it "copies each account's switch and cutoffs from the track columns" do
    run(:down)
    off = account("off@example.com").tap { |user| write_track_columns(user, suggestions: false, cutoffs: cutoffs) }
    on = account("on@example.com").tap { |user| write_track_columns(user, suggestions: true, cutoffs: {}) }

    run(:up)

    expect(off.reload).to have_attributes(level_suggestions: false, level_suggestion_cutoffs: cutoffs)
    expect(on.reload).to have_attributes(level_suggestions: true, level_suggestion_cutoffs: {})
  end

  it "rolls back to the track columns untouched" do
    user = account("kept@example.com").tap { |account| write_track_columns(account, suggestions: false, cutoffs: cutoffs) }

    run(:down)

    expect(connection.column_exists?(:users, :level_suggestions)).to be(false)
    expect(connection.column_exists?(:users, :level_suggestion_cutoffs)).to be(false)
    values = column_values(user, :track_suggestions, :track_evidence_cutoffs)
    expect(values["track_suggestions"]).to be(false)
    expect(JSON.parse(values["track_evidence_cutoffs"])).to eq(cutoffs)
    run(:up)
  end
end
