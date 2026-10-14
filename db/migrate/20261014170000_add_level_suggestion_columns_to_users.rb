# The track columns stay for one release, so code still serving during the pre-deploy migration keeps working.
class AddLevelSuggestionColumnsToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :level_suggestions, :boolean, default: true, null: false
    add_column :users, :level_suggestion_cutoffs, :jsonb, default: {}, null: false
    execute <<~SQL
      UPDATE users SET level_suggestions = track_suggestions, level_suggestion_cutoffs = track_evidence_cutoffs
    SQL
  end

  def down
    remove_column :users, :level_suggestion_cutoffs
    remove_column :users, :level_suggestions
  end
end
