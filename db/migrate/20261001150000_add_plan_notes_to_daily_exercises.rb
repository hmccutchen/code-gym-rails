# What the day's plan did that the dashboard explains, written with the row.
# Default {} and no backfill: an older day carries no note, which is correct,
# since no plan before this one added a section or shared a concept.
class AddPlanNotesToDailyExercises < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_exercises, :plan_notes, :jsonb, default: {}, null: false
  end
end
