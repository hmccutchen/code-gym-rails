# Reasoning in docs/code-notes/db/migrate/20261104150000_give_users_name_a_default.md.
class GiveUsersNameADefault < ActiveRecord::Migration[8.1]
  PLACEHOLDER = "Member".freeze

  def up
    if column_exists?(:users, :name)
      change_column_default :users, :name, PLACEHOLDER
    else
      add_column :users, :name, :string, null: false, default: PLACEHOLDER
    end
  end

  def down
    change_column_default :users, :name, nil if column_exists?(:users, :name)
  end
end
