class AddSectionRatingsToDailyResponses < ActiveRecord::Migration[8.0]
  def up
    add_column :daily_responses, :section_ratings, :jsonb, default: {}, null: false
    rename_column :daily_responses, :rating, :legacy_rating
    # Convert integer enum values to strings
    execute <<~SQL
      UPDATE daily_responses
      SET legacy_rating = CASE legacy_rating
        WHEN 0 THEN 'too_easy'
        WHEN 1 THEN 'right_level'
        WHEN 2 THEN 'too_hard'
        ELSE NULL
      END
    SQL
    change_column :daily_responses, :legacy_rating, :string
  end

  def down
    change_column :daily_responses, :legacy_rating, :integer
    # Convert strings back to integer enum values
    execute <<~SQL
      UPDATE daily_responses
      SET legacy_rating = CASE legacy_rating
        WHEN 'too_easy' THEN 0
        WHEN 'right_level' THEN 1
        WHEN 'too_hard' THEN 2
        ELSE NULL
      END
    SQL
    rename_column :daily_responses, :legacy_rating, :rating
    remove_column :daily_responses, :section_ratings
  end
end
