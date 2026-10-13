class CreateFeaturedConcepts < ActiveRecord::Migration[8.1]
  def change
    create_table :featured_concepts do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.date :week_of, null: false
      t.string :bucket, null: false
      t.string :concept, null: false
      t.timestamps
    end

    # Unique so two first visits in the same week cannot both store a pick.
    add_index :featured_concepts, [ :user_id, :week_of ], unique: true
  end
end
