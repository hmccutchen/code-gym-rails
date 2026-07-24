class AddReviewingSinceToDailyResponses < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_responses, :reviewing_since, :datetime
  end
end
