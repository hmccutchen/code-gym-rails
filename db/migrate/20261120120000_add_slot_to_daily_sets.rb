class AddSlotToDailySets < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_exercises, :slot, :integer, null: false, default: 1
    add_column :daily_responses, :slot, :integer, null: false, default: 1

    remove_index :daily_exercises, [ :user_id, :date ], unique: true
    remove_index :daily_responses, [ :user_id, :date ], unique: true
    add_index :daily_exercises, [ :user_id, :date, :slot ], unique: true
    add_index :daily_responses, [ :user_id, :date, :slot ], unique: true

    add_check_constraint :daily_exercises, "slot BETWEEN 1 AND 2", name: "daily_exercises_slot_range"
    add_check_constraint :daily_responses, "slot BETWEEN 1 AND 2", name: "daily_responses_slot_range"
  end
end
