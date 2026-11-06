class AddMasteryReconciliationState < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_responses, :mastery_application, :jsonb, default: {}, null: false
    add_column :concept_masteries, :review_reconciliation, :jsonb, default: {}, null: false
  end
end
