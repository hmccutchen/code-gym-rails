require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261016130000_add_track_chosen_at_to_users.rb")
require migration_path.to_s

RSpec.describe AddTrackChosenAtToUsers do
  let(:connection) { ActiveRecord::Base.connection }

  after { User.reset_column_information }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    User.reset_column_information
  end

  def chosen_at(user)
    connection.select_value("SELECT track_chosen_at FROM users WHERE id = #{user.id}")
  end

  it "marks every account that answered the welcome question as having chosen, at its creation time" do
    created = Time.utc(2026, 9, 1, 12)
    junior = User.create!(email: "junior@example.com", name: "Junior", learning_track: "junior", created_at: created)
    backfilled = User.create!(email: "none@example.com", name: "None", learning_track: "none", created_at: created)
    undecided = User.create!(email: "new@example.com", name: "New", learning_track: nil)
    migrate(:down)

    migrate(:up)

    expect(chosen_at(junior)).to eq(created)
    expect(chosen_at(backfilled)).to eq(created)
    expect(chosen_at(undecided)).to be_nil
  end

  it "rolls back by removing the column and leaving learning_track as it was" do
    user = User.create!(email: "kept@example.com", name: "Kept")
    user.update_columns(learning_track: "junior")

    migrate(:down)

    expect(connection.column_exists?(:users, :track_chosen_at)).to be(false)
    expect(connection.select_value("SELECT learning_track FROM users WHERE id = #{user.id}")).to eq("junior")
  ensure
    migrate(:up)
  end
end
