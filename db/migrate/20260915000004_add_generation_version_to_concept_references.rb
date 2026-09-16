class AddGenerationVersionToConceptReferences < ActiveRecord::Migration[8.0]
  def change
    add_column :concept_references, :generation_version, :bigint, default: 0, null: false
  end
end
