class AddLessonToConceptReferences < ActiveRecord::Migration[8.1]
  def change
    add_column :concept_references, :lesson, :jsonb
  end
end
