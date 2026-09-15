class AddDifficultyLadderToConceptReferences < ActiveRecord::Migration[8.0]
  def change
    add_column :concept_references, :ladder_junior,             :text
    add_column :concept_references, :ladder_senior,             :text
    add_column :concept_references, :ladder_principal_engineer, :text
  end
end
