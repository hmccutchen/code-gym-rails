class CreateConceptMasteries < ActiveRecord::Migration[8.0]
  def change
    create_table :concept_masteries do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :concept,  null: false
      t.string  :language, null: false
      t.integer :tier,     null: false, default: 0
      t.integer :streak,   null: false, default: 0
      t.integer :cooldown_remaining, null: false, default: 0
      t.string  :last_rating
      t.timestamps
    end
    add_index :concept_masteries, [ :user_id, :concept, :language ], unique: true
  end
end
