class AddPushRemindersEnabledToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :push_reminders_enabled, :boolean, default: false, null: false
  end
end
