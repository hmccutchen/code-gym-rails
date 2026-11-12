class AddKeySavedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :key_saved_at, :jsonb, default: {}, null: false
  end
end
