class AddRetentionScheduleToConceptMasteries < ActiveRecord::Migration[8.0]
  def change
    add_column :concept_masteries, :mastered_at,             :datetime
    add_column :concept_masteries, :next_retention_check_on, :date
    add_column :concept_masteries, :retention_interval_days, :integer
    add_index  :concept_masteries, [ :user_id, :next_retention_check_on ]
  end
end
