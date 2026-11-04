require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261104150000_give_users_name_a_default.rb")
require migration_path.to_s

RSpec.describe GiveUsersNameADefault do
  let(:connection) { ActiveRecord::Base.connection }

  after { User.reset_column_information }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    User.reset_column_information
  end

  def name_column
    connection.columns(:users).find { |column| column.name == "name" }
  end

  def insert_without_a_name
    connection.execute("INSERT INTO users (email, created_at, updated_at) VALUES ('nameless@example.com', now(), now())")
  end

  it "gives the column a nonblank default and keeps it required, so the release still serving can validate what an email-only insert stores" do
    migrate(:down)
    expect { connection.transaction(requires_new: true) { insert_without_a_name } }.to raise_error(ActiveRecord::NotNullViolation)

    migrate(:up)
    insert_without_a_name

    expect(name_column).to have_attributes(null: false, default: "Member")
    expect(connection.select_value("SELECT name FROM users WHERE email = 'nameless@example.com'")).to eq("Member")
  end

  it "makes a column that an earlier version of this change left nullable required again, filling its nulls" do
    migrate(:down)
    connection.change_column_null(:users, :name, true)
    user = User.create!(email: "null@example.com")
    connection.execute("UPDATE users SET name = NULL WHERE id = #{user.id}")

    migrate(:up)

    expect(name_column).to have_attributes(null: false, default: "Member")
    expect(connection.select_value("SELECT name FROM users WHERE id = #{user.id}")).to eq("Member")
  ensure
    migrate(:up)
  end

  it "leaves the names already stored alone, in both directions" do
    migrate(:up)
    user = User.create!(email: "named@example.com")
    connection.execute("UPDATE users SET name = 'Real Person' WHERE id = #{user.id}")

    migrate(:down)
    migrate(:up)

    expect(connection.select_value("SELECT name FROM users WHERE id = #{user.id}")).to eq("Real Person")
  end

  it "rolls back by removing the default and keeping the column required" do
    migrate(:down)

    expect(name_column).to have_attributes(null: false, default: nil)
  ensure
    migrate(:up)
  end

  it "adds the column with the default when a database already dropped it, and removes nothing on the way back" do
    connection.remove_column(:users, :name)
    User.reset_column_information

    migrate(:up)

    expect(name_column).to have_attributes(null: false, default: "Member")
    migrate(:down)
    expect(name_column).to have_attributes(null: false, default: nil)
  ensure
    migrate(:up)
  end
end
