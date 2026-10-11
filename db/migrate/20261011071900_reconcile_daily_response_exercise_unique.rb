require_relative "20261011040000_make_daily_response_exercise_unique"

class ReconcileDailyResponseExerciseUnique < ActiveRecord::Migration[8.1]
  def up
    return if index_exists?(:daily_responses, :daily_exercise_id, unique: true)

    MakeDailyResponseExerciseUnique.new.up
  end

  # The original migration owns this index, including its rollback.
  def down
  end
end
