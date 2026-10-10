# No backfill: no plan before this one added a section or shared a concept, so {} is correct.
class AddPlanNotesToDailyExercises < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_exercises, :plan_notes, :jsonb, default: {}, null: false
  end
end
