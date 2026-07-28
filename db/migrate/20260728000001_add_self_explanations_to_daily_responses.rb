class AddSelfExplanationsToDailyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_responses, :self_explanations, :jsonb, default: {}, null: false
  end
end
