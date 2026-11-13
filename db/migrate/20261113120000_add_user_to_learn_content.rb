# Shared rows keep user_id NULL until they are copied to each user (docs/decisions/learn-content-per-user.md).
class AddUserToLearnContent < ActiveRecord::Migration[8.1]
  def change
    add_reference :concept_references, :user, foreign_key: true, index: false
    add_reference :recognition_guides, :user, foreign_key: true, index: false

    add_index :concept_references, %i[user_id concept language], unique: true
    add_index :recognition_guides, %i[user_id group_key], unique: true

    remove_index :concept_references, %i[concept language], unique: true, name: "index_concept_references_on_concept_and_language"
    add_index :concept_references, %i[concept language], unique: true, where: "user_id IS NULL",
      name: "index_concept_references_shared_on_concept_and_language"
    remove_index :recognition_guides, :group_key, unique: true, name: "index_recognition_guides_on_group_key"
    add_index :recognition_guides, :group_key, unique: true, where: "user_id IS NULL",
      name: "index_recognition_guides_shared_on_group_key"
  end
end
