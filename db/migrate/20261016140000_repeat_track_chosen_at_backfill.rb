# Reasoning in docs/code-notes/db/migrate/20261016130000_add_track_chosen_at_to_users.md.
class RepeatTrackChosenAtBackfill < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET track_chosen_at = created_at WHERE learning_track IS NOT NULL AND track_chosen_at IS NULL"
  end

  def down; end
end
