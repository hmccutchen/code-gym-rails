class AddDroppedSectionsToDailyExercises < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_exercises, :dropped_sections, :jsonb, default: [], null: false
  end
end
