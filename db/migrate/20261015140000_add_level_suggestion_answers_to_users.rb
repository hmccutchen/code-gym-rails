# The old counter stays, ignored by User, while the old code serves through this pre-deploy migration.
class AddLevelSuggestionAnswersToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :level_suggestion_answers, :integer, default: 0, null: false
    execute "UPDATE users SET level_suggestion_answers = track_proposals_answered"
  end

  def down
    remove_column :users, :level_suggestion_answers
  end
end
