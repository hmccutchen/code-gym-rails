class AddFeaturedOnToConceptReferences < ActiveRecord::Migration[8.0]
  def change
    add_column :concept_references, :featured_on, :date

    # Unique rather than plain: exactly one row may hold a given date, so two
    # concurrent first-visits of the day cannot both stamp a pick. Postgres
    # allows many NULLs under a unique index, so every never-featured row still
    # sits here.
    add_index :concept_references, :featured_on, unique: true
  end
end
