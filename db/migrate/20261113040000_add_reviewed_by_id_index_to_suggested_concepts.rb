class AddReviewedByIdIndexToSuggestedConcepts < ActiveRecord::Migration[8.1]
  def change
    add_index :suggested_concepts, :reviewed_by_id
  end
end
