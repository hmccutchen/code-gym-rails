class AddSlotToDailySets < ActiveRecord::Migration[8.1]
  LOCK_TIMEOUT = "5s"

  def up
    limit_lock_wait
    add_column :daily_exercises, :slot, :integer, null: false, default: 1
    add_column :daily_responses, :slot, :integer, null: false, default: 1

    remove_index :daily_exercises, [ :user_id, :date ], unique: true
    remove_index :daily_responses, [ :user_id, :date ], unique: true
    add_index :daily_exercises, [ :user_id, :date, :slot ], unique: true
    add_index :daily_responses, [ :user_id, :date, :slot ], unique: true

    add_check_constraint :daily_exercises, "slot BETWEEN 1 AND 2", name: "daily_exercises_slot_range"
    add_check_constraint :daily_responses, "slot BETWEEN 1 AND 2", name: "daily_responses_slot_range"
  end

  def down
    limit_lock_wait
    refuse_once_a_day_holds_a_second_set

    remove_check_constraint :daily_responses, name: "daily_responses_slot_range"
    remove_check_constraint :daily_exercises, name: "daily_exercises_slot_range"

    remove_index :daily_responses, [ :user_id, :date, :slot ], unique: true
    remove_index :daily_exercises, [ :user_id, :date, :slot ], unique: true
    add_index :daily_responses, [ :user_id, :date ], unique: true
    add_index :daily_exercises, [ :user_id, :date ], unique: true

    remove_column :daily_responses, :slot
    remove_column :daily_exercises, :slot
  end

  private

  def limit_lock_wait = execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")

  def refuse_once_a_day_holds_a_second_set
    return unless select_value("SELECT 1 FROM daily_exercises WHERE slot > 1 LIMIT 1")

    raise ActiveRecord::IrreversibleMigration,
      "A day holds a second set, and one set per user and date can't be restored without deleting it"
  end
end
