require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261015140000_add_level_suggestion_answers_to_users.rb")
require migration_path.to_s

RSpec.describe AddLevelSuggestionAnswersToUsers do
  let(:connection) { ActiveRecord::Base.connection }

  after { User.reset_column_information }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    User.reset_column_information
  end

  def old_count(user_id)
    connection.select_value("SELECT track_proposals_answered FROM users WHERE id = #{user_id}")
  end

  it "copies each account's answer count from the old column" do
    answered = User.create!(email: "answered@example.com", name: "Answered")
    untouched = User.create!(email: "untouched@example.com", name: "Untouched")
    migrate(:down)
    connection.exec_update("UPDATE users SET track_proposals_answered = 4 WHERE id = #{answered.id}")

    migrate(:up)

    expect(answered.reload.level_suggestion_answers).to eq(4)
    expect(untouched.reload.level_suggestion_answers).to eq(0)
  end

  it "rolls back by removing the new column and leaving the old count as it was" do
    user = User.create!(email: "kept@example.com", name: "Kept")
    connection.exec_update("UPDATE users SET track_proposals_answered = 2 WHERE id = #{user.id}")

    migrate(:down)

    expect(connection.column_exists?(:users, :level_suggestion_answers)).to be(false)
    expect(old_count(user.id)).to eq(2)
  ensure
    migrate(:up)
  end

  it "keeps the old column out of User for one release" do
    expect(User.column_names).not_to include("track_proposals_answered")
    expect(connection.column_exists?(:users, :track_proposals_answered)).to be(true)
  end
end
