require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261016120000_remove_track_leftovers_from_users.rb")
require migration_path.to_s

RSpec.describe RemoveTrackLeftoversFromUsers do
  let(:connection) { ActiveRecord::Base.connection }
  let(:old_columns) { %w[track_suggestions track_evidence_cutoffs track_proposals_answered] }

  after { User.reset_column_information }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    User.reset_column_information
  end

  it "leaves the users table without the track columns" do
    expect(connection.columns(:users).map(&:name)).not_to include(*old_columns)
  end

  it "rolls back by restoring the columns with their defaults" do
    user = User.create!(email: "kept@example.com", name: "Kept")

    migrate(:down)

    row = connection.select_one("SELECT #{old_columns.join(', ')} FROM users WHERE id = #{user.id}")
    expect(row).to eq("track_suggestions" => true, "track_evidence_cutoffs" => "{}", "track_proposals_answered" => 0)
  ensure
    migrate(:up)
  end
end
