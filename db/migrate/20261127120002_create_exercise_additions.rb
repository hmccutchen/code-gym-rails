class CreateExerciseAdditions < ActiveRecord::Migration[8.1]
  def change
    create_table :exercise_additions do |t|
      t.references :daily_exercise, null: false, foreign_key: true, index: false
      t.uuid :request_uuid, null: false
      t.string :kind, null: false
      t.string :draft_scope, null: false
      t.date :date, null: false
      t.string :status, null: false, default: "queued"
      t.datetime :claimed_at
      t.timestamps

      t.index %i[daily_exercise_id request_uuid], unique: true
      t.index :daily_exercise_id, unique: true, where: "status IN ('queued', 'running')",
        name: "index_exercise_additions_one_active_per_exercise"
      t.check_constraint "status IN ('queued', 'running', 'succeeded', 'failed')", name: "exercise_additions_status"
    end
  end
end
