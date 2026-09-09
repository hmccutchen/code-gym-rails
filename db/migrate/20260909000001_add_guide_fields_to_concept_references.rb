class AddGuideFieldsToConceptReferences < ActiveRecord::Migration[8.0]
  def change
    add_column :concept_references, :guide_plain_language, :text
    add_column :concept_references, :guide_worked_example, :text
    add_column :concept_references, :guide_pitfalls,       :text
  end
end
