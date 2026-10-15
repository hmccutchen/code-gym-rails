# Safe only once the release that stopped reading these columns is serving every process.
class RemoveTrackLeftoversFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :track_suggestions, :boolean, default: true, null: false
    remove_column :users, :track_evidence_cutoffs, :jsonb, default: {}, null: false
    remove_column :users, :track_proposals_answered, :integer, default: 0, null: false
  end
end
