class ConvertLegacyRatingToString < ActiveRecord::Migration[8.0]
  def up
    # Convert integer enum values to strings, then change column type
    change_column :daily_responses, :legacy_rating, :string, default: nil, using: 'CASE WHEN legacy_rating = 0 THEN \'too_easy\' WHEN legacy_rating = 1 THEN \'right_level\' WHEN legacy_rating = 2 THEN \'too_hard\' ELSE NULL END'
  end

  def down
    # Convert strings back to integer enum values, then change column type
    change_column :daily_responses, :legacy_rating, :integer, default: nil, using: 'CASE WHEN legacy_rating = \'too_easy\' THEN 0 WHEN legacy_rating = \'right_level\' THEN 1 WHEN legacy_rating = \'too_hard\' THEN 2 ELSE NULL END'
  end
end
