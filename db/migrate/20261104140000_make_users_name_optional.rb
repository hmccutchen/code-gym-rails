# Reasoning in docs/code-notes/db/migrate/20261104140000_make_users_name_optional.md.
class MakeUsersNameOptional < ActiveRecord::Migration[8.1]
  def up
    change_column_null :users, :name, true if column_exists?(:users, :name)
  end

  def down
    change_column_null :users, :name, false, "" if column_exists?(:users, :name)
  end
end
