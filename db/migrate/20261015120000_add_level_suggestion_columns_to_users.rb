# The track columns stay, ignored by User, while the old code serves through this pre-deploy migration.
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
