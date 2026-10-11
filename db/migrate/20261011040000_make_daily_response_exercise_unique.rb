# Duplicates were left by carry-forward moving an exercise without its draft (#348).
class MakeDailyResponseExerciseUnique < ActiveRecord::Migration[8.1]
  def up
    delete_extra_drafts
    refuse_remaining_duplicates
    remove_index :daily_responses, :daily_exercise_id
    add_index :daily_responses, :daily_exercise_id, unique: true
  end

  def down
    remove_index :daily_responses, :daily_exercise_id
    add_index :daily_responses, :daily_exercise_id
  end

  private

  def delete_extra_drafts
    execute <<~SQL
      DELETE FROM daily_responses
      WHERE id IN (
        SELECT ranked.id FROM (
          SELECT responses.id, responses.submitted_at,
                 row_number() OVER (
                   PARTITION BY responses.daily_exercise_id
                   ORDER BY (responses.date = exercises.date) DESC, responses.date DESC, responses.id DESC
                 ) AS position
          FROM daily_responses responses
          JOIN daily_exercises exercises ON exercises.id = responses.daily_exercise_id
        ) ranked
        WHERE ranked.position > 1 AND ranked.submitted_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM review_follow_ups WHERE review_follow_ups.daily_response_id = ranked.id)
      )
    SQL
  end

  def refuse_remaining_duplicates
    exercise_ids = select_values(<<~SQL)
      SELECT daily_exercise_id FROM daily_responses GROUP BY daily_exercise_id HAVING count(*) > 1 ORDER BY daily_exercise_id
    SQL
    return if exercise_ids.empty?

    raise ActiveRecord::MigrationError,
          "Submitted responses share an exercise (daily_exercise_id #{exercise_ids.join(', ')}); decide which to keep before adding the unique index."
  end
end
