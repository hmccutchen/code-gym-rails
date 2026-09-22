class RemoveSelfExplanationsFromDailyResponses < ActiveRecord::Migration[8.1]
  def change
    remove_column :daily_responses, :self_explanations, :jsonb, default: {}, null: false
  end
end
