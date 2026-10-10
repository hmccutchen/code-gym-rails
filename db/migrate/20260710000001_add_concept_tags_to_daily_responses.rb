# Copied at answer time so concept history is a plain column query that survives problem_set regeneration.
class AddConceptTagsToDailyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_responses, :concept_tags, :jsonb, default: {}, null: false
  end
end
