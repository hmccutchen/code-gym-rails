class AddDisplayPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :display_preferences, :jsonb, default: {}, null: false
  end
end
