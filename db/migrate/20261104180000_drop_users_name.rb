# Reasoning in docs/code-notes/db/migrate/20261104180000_drop_users_name.md.
class DropUsersName < ActiveRecord::Migration[8.1]
  def up
    remove_column :users, :name if column_exists?(:users, :name)
  end

  def down
    add_column :users, :name, :string, null: false, default: "Member" unless column_exists?(:users, :name)
  end
end
