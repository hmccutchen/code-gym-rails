# Reasoning in docs/code-notes/db/migrate/20261016130000_add_track_chosen_at_to_users.md.
class AddTrackChosenAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :track_chosen_at, :datetime
    execute "UPDATE users SET track_chosen_at = created_at WHERE learning_track IS NOT NULL"
  end

  def down
    remove_column :users, :track_chosen_at
  end
end
