# Which provider wrote a response's review, so switching providers does not
# relabel past reviews. Until now each user had one provider, so a reviewed
# response's provider is its user's.
class AddReviewProviderToDailyResponses < ActiveRecord::Migration[8.1]
  def up
    add_column :daily_responses, :review_provider, :string
    execute <<~SQL
      UPDATE daily_responses
      SET review_provider = users.provider
      FROM users
      WHERE daily_responses.user_id = users.id
        AND daily_responses.ai_review IS NOT NULL
        AND daily_responses.ai_review <> '{}'::jsonb
    SQL
  end

  def down
    remove_column :daily_responses, :review_provider
  end
end
