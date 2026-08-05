class AddReviewErrorsToDailyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_responses, :review_errors, :jsonb, default: {}, null: false
  end
end
