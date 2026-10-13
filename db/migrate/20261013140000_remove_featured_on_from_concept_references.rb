# Safe only once the release that stopped reading this column is serving every process.
class RemoveFeaturedOnFromConceptReferences < ActiveRecord::Migration[8.1]
  def change
    remove_index :concept_references, :featured_on, unique: true
    remove_column :concept_references, :featured_on, :date
  end
end
