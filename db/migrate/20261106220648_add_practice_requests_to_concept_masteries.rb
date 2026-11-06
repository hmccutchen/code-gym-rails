class AddPracticeRequestsToConceptMasteries < ActiveRecord::Migration[8.1]
  def change
    add_column :concept_masteries, :practice_requests, :jsonb, default: {}, null: false
  end
end
