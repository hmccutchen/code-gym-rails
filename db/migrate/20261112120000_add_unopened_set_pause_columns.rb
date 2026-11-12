class AddUnopenedSetPauseColumns < ActiveRecord::Migration[8.1]
  def up
    add_column :daily_exercises, :opened_at, :datetime
    add_column :users, :generation_pause_source, :string
    add_column :users, :generation_account_failures, :integer, default: 0, null: false

    execute "UPDATE daily_exercises SET opened_at = created_at"
    execute "UPDATE users SET generation_pause_source = 'manual' WHERE paused_generation_at IS NOT NULL"
  end

  def down
    remove_column :users, :generation_account_failures
    remove_column :users, :generation_pause_source
    remove_column :daily_exercises, :opened_at
  end
end
