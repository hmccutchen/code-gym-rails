require "rails_helper"

require Rails.root.join("db/migrate/20261104180000_drop_users_name.rb").to_s

RSpec.describe DropUsersName do
  let(:connection) { ActiveRecord::Base.connection }

  after do
    migrate(:down)
    User.reset_column_information
  end

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  it "drops the name column, and does nothing when it is already gone" do
    migrate(:up)
    expect(connection.column_exists?(:users, :name)).to be(false)

    expect { migrate(:up) }.not_to raise_error
  end

  it "adds the column back required with the placeholder default, so a rollback leaves a table the previous release can insert into" do
    migrate(:up)
    migrate(:down)

    column = connection.columns(:users).find { |candidate| candidate.name == "name" }
    expect(column).to have_attributes(null: false, default: "Member")
  end
end
