class CreateDuckThreads < ActiveRecord::Migration[8.1]
  def change
    create_table :duck_threads do |t|
      t.references :user, null: false, foreign_key: true
      t.references :daily_exercise, null: false, foreign_key: true, index: { unique: true }
      t.string :draft_scope, null: false
      t.jsonb :threads, null: false, default: {}
      t.timestamps
    end
  end
end
