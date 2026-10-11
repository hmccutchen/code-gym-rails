class AddTrackSuggestionControlsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :track_suggestions, :boolean, default: true, null: false
    add_column :users, :track_proposals_answered, :integer, default: 0, null: false
  end
end
