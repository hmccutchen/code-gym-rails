# DailyExercise is unique per user and date, so this resets daily without bookkeeping.
class AddRegeneratedAtToDailyExercises < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_exercises, :regenerated_at, :datetime
  end
end
