class AddPseudocodeRoundsToDailyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_responses, :pseudocode_rounds, :jsonb, default: {}, null: false
  end
end
