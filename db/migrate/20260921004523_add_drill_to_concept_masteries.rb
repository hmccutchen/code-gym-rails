class AddDrillToConceptMasteries < ActiveRecord::Migration[8.1]
  def change
    add_column :concept_masteries, :drilled_at, :datetime
    add_column :concept_masteries, :drill_group, :string
  end
end
