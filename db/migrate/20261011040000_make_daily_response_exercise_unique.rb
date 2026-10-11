# Duplicates were left by carry-forward moving an exercise without its draft (#348).
class MakeDailyResponseExerciseUnique < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DELETE FROM review_follow_ups WHERE daily_response_id IN (#{extra_responses});
      DELETE FROM daily_responses WHERE id IN (#{extra_responses});
    SQL
    remove_index :daily_responses, :daily_exercise_id
    add_index :daily_responses, :daily_exercise_id, unique: true
  end

  def down
    remove_index :daily_responses, :daily_exercise_id
    add_index :daily_responses, :daily_exercise_id
  end

  private

  def extra_responses
    <<~SQL
      SELECT ranked.id FROM (
        SELECT responses.id,
               row_number() OVER (
                 PARTITION BY responses.daily_exercise_id
                 ORDER BY (responses.date = exercises.date) DESC, responses.date DESC, responses.id DESC
               ) AS position
        FROM daily_responses responses
        JOIN daily_exercises exercises ON exercises.id = responses.daily_exercise_id
      ) ranked
      WHERE ranked.position > 1
    SQL
  end
end
