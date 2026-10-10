# Existing accounts are never asked the onboarding question; "none" records that, so first_run? needs no date.
class BackfillLearningTrackForExistingUsers < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET learning_track = 'none' WHERE learning_track IS NULL"
  end

  # Irreversible: the marked rows look like any chosen "none", so nothing is safe to undo.
  def down; end
end
