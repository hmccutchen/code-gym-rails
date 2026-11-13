# Reasoning in docs/code-notes/db/migrate/20261113190000_require_user_on_learn_content.md.
require_relative "20261113150000_copy_shared_learn_content"

class RequireUserOnLearnContent < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s"

  def self.require_owner(connection)
    connection.execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
    connection.execute("LOCK TABLE concept_references, recognition_guides IN ACCESS EXCLUSIVE MODE")
    connection.execute("DELETE FROM concept_references WHERE user_id IS NULL")
    connection.execute("DELETE FROM recognition_guides WHERE user_id IS NULL")

    connection.remove_index :concept_references, name: "index_concept_references_shared_on_concept_and_language", if_exists: true
    connection.remove_index :recognition_guides, name: "index_recognition_guides_shared_on_group_key", if_exists: true
    connection.change_column_null :concept_references, :user_id, false
    connection.change_column_null :recognition_guides, :user_id, false
  end

  def self.allow_shared_rows(connection)
    connection.change_column_null :concept_references, :user_id, true
    connection.change_column_null :recognition_guides, :user_id, true
    connection.add_index :concept_references, %i[concept language], unique: true, where: "user_id IS NULL",
      name: "index_concept_references_shared_on_concept_and_language", if_not_exists: true
    connection.add_index :recognition_guides, :group_key, unique: true, where: "user_id IS NULL",
      name: "index_recognition_guides_shared_on_group_key", if_not_exists: true
  end

  def up
    CopySharedLearnContent.copy_to_active_users(connection)
    connection.transaction { self.class.require_owner(connection) }
  end

  def down
    connection.transaction { self.class.allow_shared_rows(connection) }
  end
end
