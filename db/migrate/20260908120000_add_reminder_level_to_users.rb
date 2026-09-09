class AddReminderLevelToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :reminder_level, :integer, default: 0, null: false
    execute "UPDATE users SET reminder_level = 1 WHERE push_reminders_enabled = TRUE"
  end

  def down
    remove_column :users, :reminder_level
  end
end
