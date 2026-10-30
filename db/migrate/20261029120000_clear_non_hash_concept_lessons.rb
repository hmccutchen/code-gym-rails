class ClearNonHashConceptLessons < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE concept_references
      SET lesson = NULL
      WHERE lesson IS NOT NULL AND jsonb_typeof(lesson) <> 'object'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
