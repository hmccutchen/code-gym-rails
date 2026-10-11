class MakeDailyResponseExerciseUnique < ActiveRecord::Migration[8.1]
  def change
    remove_index :daily_responses, :daily_exercise_id
    add_index :daily_responses, :daily_exercise_id, unique: true
  end
end
