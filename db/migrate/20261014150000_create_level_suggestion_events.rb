class CreateLevelSuggestionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :level_suggestion_events do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :action, null: false
      t.string :source
      t.string :from_level
      t.string :to_level
      t.integer :window_size, null: false, default: 0
      t.integer :favourable, null: false, default: 0
      t.integer :too_hard_latest3, null: false, default: 0
      t.date :newest_result_on
      t.datetime :created_at, null: false
    end
  end
end
