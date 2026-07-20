class CreateSuggestedConcepts < ActiveRecord::Migration[8.0]
  def change
    create_table :suggested_concepts do |t|
      t.string   :language,        null: false
      t.string   :normalized_name, null: false
      t.string   :display_name,    null: false
      t.integer  :occurrences,     null: false, default: 1
      t.datetime :first_seen_at,   null: false
      t.datetime :last_seen_at,    null: false
      t.string   :status,          null: false, default: "pending"
      t.datetime :reviewed_at
      t.bigint   :reviewed_by_id

      t.timestamps
    end

    add_index :suggested_concepts, [ :language, :normalized_name ], unique: true,
      name: "index_suggested_concepts_on_language_and_normalized_name"
    add_index :suggested_concepts, :status
  end
end
