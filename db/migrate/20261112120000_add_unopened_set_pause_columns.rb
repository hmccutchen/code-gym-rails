class AddUnopenedSetPauseColumns < ActiveRecord::Migration[8.1]
  # Users before daily_exercises, the order PracticeGeneration.commit_new locks them, so the two can't deadlock.
  def up
    add_column :users, :generation_pause_source, :string
    add_column :users, :generation_account_failures, :integer, default: 0, null: false
    execute "UPDATE users SET generation_pause_source = 'manual' WHERE paused_generation_at IS NOT NULL"

    add_column :daily_exercises, :opened_at, :datetime
    execute "UPDATE daily_exercises SET opened_at = created_at"
  end

  def down
    remove_column :users, :generation_account_failures
    remove_column :users, :generation_pause_source
    remove_column :daily_exercises, :opened_at
  end
end
