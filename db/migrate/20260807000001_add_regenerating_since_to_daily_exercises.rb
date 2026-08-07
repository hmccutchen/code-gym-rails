class AddRegeneratingSinceToDailyExercises < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_exercises, :regenerating_since, :datetime
  end
end
