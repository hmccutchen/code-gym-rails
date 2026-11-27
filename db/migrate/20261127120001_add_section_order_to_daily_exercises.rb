class AddSectionOrderToDailyExercises < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_exercises, :section_order, :jsonb
  end
end
