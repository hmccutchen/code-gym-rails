# Denormalized copy of each answered problem's concept (from the exercise's
# problem_set jsonb), keyed by section name. Copied at answer time so
# per-user concept history is a plain column query and survives any future
# problem_set regeneration.
class AddConceptTagsToDailyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_responses, :concept_tags, :jsonb, default: {}
  end
end
