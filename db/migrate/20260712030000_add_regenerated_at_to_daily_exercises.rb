# Tracks whether today's exercise set has already been manually regenerated
# via the dashboard "Generate new set" button (separate from the 8am cron).
# DailyExercise is unique per user_id + date, so this naturally resets to nil
# every day without any extra bookkeeping.
class AddRegeneratedAtToDailyExercises < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_exercises, :regenerated_at, :datetime
  end
end
