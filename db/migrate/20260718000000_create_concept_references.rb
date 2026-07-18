class CreateConceptReferences < ActiveRecord::Migration[8.0]
  def change
    create_table :concept_references do |t|
      t.string :concept,      null: false
      t.string :language,     null: false
      t.text   :tagline
      t.text   :explanation
      t.text   :code_example
      t.text   :senior_lens

      t.timestamps
    end

    add_index :concept_references, [ :concept, :language ], unique: true
  end
end
