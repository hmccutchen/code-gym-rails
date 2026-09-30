class AddLearningTrackToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :learning_track, :string
    add_column :users, :track_evidence_cutoffs, :jsonb, default: {}, null: false
  end
end
