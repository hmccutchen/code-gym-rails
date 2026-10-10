# No trial flag: a present trial_ends_at is the trial.
class AddTrialToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :invite_code, null: true, foreign_key: true
    add_column :users, :trial_started_at, :datetime
    add_column :users, :trial_ends_at, :datetime
    add_column :users, :trial_consented_at, :datetime
  end
end
