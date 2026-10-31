class DropLegacyRatingFromDailyResponses < ActiveRecord::Migration[8.1]
  def change
    remove_column :daily_responses, :legacy_rating, :string
  end
end
