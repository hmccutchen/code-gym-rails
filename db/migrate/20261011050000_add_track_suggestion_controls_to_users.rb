# The PR app ran this under an earlier version number, so its columns can already exist.
class AddTrackSuggestionControlsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :track_suggestions, :boolean, default: true, null: false, if_not_exists: true
    add_column :users, :track_proposals_answered, :integer, default: 0, null: false, if_not_exists: true
  end
end
