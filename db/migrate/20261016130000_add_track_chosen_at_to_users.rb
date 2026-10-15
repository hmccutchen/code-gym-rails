# Ships a release before any code reads the column, so a worker on new code never meets a database without it.
class AddTrackChosenAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :track_chosen_at, :datetime
    execute "UPDATE users SET track_chosen_at = created_at WHERE learning_track IS NOT NULL"
  end

  def down
    remove_column :users, :track_chosen_at
  end
end
