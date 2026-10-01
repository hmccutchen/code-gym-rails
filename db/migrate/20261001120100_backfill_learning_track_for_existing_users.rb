# Every account that exists when the learning track ships has already
# decided, in the sense the track cares about: it should never be asked the
# onboarding question. "none" is the stored form of that decision, so
# User#first_run? needs no date to tell these accounts from new ones.
class BackfillLearningTrackForExistingUsers < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET learning_track = 'none' WHERE learning_track IS NULL"
  end

  # The rows this marked cannot be told apart from accounts that chose
  # "Experienced" or left the track, so there is nothing safe to undo.
  def down; end
end
