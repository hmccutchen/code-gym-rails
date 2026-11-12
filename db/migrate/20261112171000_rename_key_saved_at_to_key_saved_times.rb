class RenameKeySavedAtToKeySavedTimes < ActiveRecord::Migration[8.1]
  def change
    rename_column :users, :key_saved_at, :key_saved_times
  end
end
