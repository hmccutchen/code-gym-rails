class CreateDailyKindSwaps < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_kind_swaps do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :place, null: false
      t.string :from_kind, null: false
      t.string :to_kind, null: false
      t.string :today_section, null: false
      t.integer :planned_size
      t.integer :size_setting
      t.datetime :created_at, null: false
    end
  end
end
