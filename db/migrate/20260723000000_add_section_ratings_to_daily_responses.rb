class AddSectionRatingsToDailyResponses < ActiveRecord::Migration[8.0]
  # The enum conversion must ride the ALTER's USING clause: a separate UPDATE
  # would assign text into the still-integer column, which Postgres rejects at
  # parse time (PG::DatatypeMismatch) — even on an empty table.
  def up
    add_column :daily_responses, :section_ratings, :jsonb, default: {}, null: false
    rename_column :daily_responses, :rating, :legacy_rating
    change_column :daily_responses, :legacy_rating, :string, using: <<~SQL
      CASE legacy_rating
        WHEN 0 THEN 'too_easy'
        WHEN 1 THEN 'right_level'
        WHEN 2 THEN 'too_hard'
      END
    SQL
  end

  def down
    change_column :daily_responses, :legacy_rating, :integer, using: <<~SQL
      CASE legacy_rating
        WHEN 'too_easy' THEN 0
        WHEN 'right_level' THEN 1
        WHEN 'too_hard' THEN 2
      END
    SQL
    rename_column :daily_responses, :legacy_rating, :rating
    remove_column :daily_responses, :section_ratings
  end
end
