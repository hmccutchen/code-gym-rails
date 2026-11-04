class DeleteJavascriptUnsafeMigrationReference < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DELETE FROM concept_references
      WHERE language = 'javascript' AND concept = 'unsafe_migration'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
