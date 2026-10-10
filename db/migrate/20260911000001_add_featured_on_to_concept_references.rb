class AddFeaturedOnToConceptReferences < ActiveRecord::Migration[8.0]
  def change
    add_column :concept_references, :featured_on, :date

    # Unique so two concurrent first visits cannot both stamp a pick; Postgres allows many NULLs.
    add_index :concept_references, :featured_on, unique: true
  end
end
