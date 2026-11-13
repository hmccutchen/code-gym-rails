# Shared rows keep user_id NULL until they are copied to each user (docs/decisions/learn-content-per-user.md).
class AddUserToLearnContent < ActiveRecord::Migration[8.1]
  def up
    add_reference :concept_references, :user, foreign_key: true, index: false
    add_reference :recognition_guides, :user, foreign_key: true, index: false

    add_index :concept_references, %i[user_id concept language], unique: true
    add_index :recognition_guides, %i[user_id group_key], unique: true

    remove_index :concept_references, name: "index_concept_references_on_concept_and_language"
    add_index :concept_references, %i[concept language], unique: true, where: "user_id IS NULL",
      name: "index_concept_references_shared_on_concept_and_language"
    remove_index :recognition_guides, name: "index_recognition_guides_on_group_key"
    add_index :recognition_guides, :group_key, unique: true, where: "user_id IS NULL",
      name: "index_recognition_guides_shared_on_group_key"
  end

  def down
    refuse_once_rows_are_owned

    remove_index :concept_references, name: "index_concept_references_shared_on_concept_and_language"
    add_index :concept_references, %i[concept language], unique: true, name: "index_concept_references_on_concept_and_language"
    remove_index :recognition_guides, name: "index_recognition_guides_shared_on_group_key"
    add_index :recognition_guides, :group_key, unique: true, name: "index_recognition_guides_on_group_key"

    remove_reference :concept_references, :user, foreign_key: true, index: false
    remove_reference :recognition_guides, :user, foreign_key: true, index: false
  end

  private

  def refuse_once_rows_are_owned
    owned = %w[concept_references recognition_guides].select do |table|
      select_value("SELECT 1 FROM #{table} WHERE user_id IS NOT NULL LIMIT 1")
    end
    return if owned.empty?

    raise ActiveRecord::IrreversibleMigration,
      "#{owned.join(' and ')} hold rows with a user_id, written by L2 or later; roll back to L2's code instead " \
      "(docs/decisions/learn-content-per-user.md, Rollback)."
  end
end
