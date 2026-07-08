class CreateDailyExercises < ActiveRecord::Migration[8.0]
  def change
    create_table :daily_exercises do |t|
      t.references :user,         null: false, foreign_key: true
      t.date       :date,         null: false
      t.jsonb      :problem_set,  null: false, default: {}
      t.datetime   :generated_at, null: false

      t.timestamps
    end

    add_index :daily_exercises, [ :user_id, :date ], unique: true
  end
end
