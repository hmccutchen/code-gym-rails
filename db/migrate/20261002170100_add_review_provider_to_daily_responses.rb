# Which provider wrote a response's review, so switching providers does not
# relabel past reviews. A user could already replace their key with another
# provider's, so the current provider is only a guess for a past review.
# api_usages.model is the only evidence of which provider ran, and it has been
# recorded only since AddModelAndCacheTokensToApiUsages. A user whose recorded
# models name another provider has reviews from an unknown provider; anyone
# else keeps the current provider, which is what the page already showed.
class AddReviewProviderToDailyResponses < ActiveRecord::Migration[8.1]
  UNKNOWN = "unknown".freeze

  # The model-name prefix each provider's routes have used, frozen here so a
  # later rename in a provider class cannot change what this migration did.
  MODEL_PREFIXES = { "anthropic" => "claude-", "gemini" => "gemini-", "openai" => "gpt-" }.freeze

  def up
    add_column :daily_responses, :review_provider, :string
    execute <<~SQL
      UPDATE daily_responses
      SET review_provider = CASE WHEN #{other_provider_recorded} THEN '#{UNKNOWN}' ELSE users.provider END
      FROM users
      WHERE daily_responses.user_id = users.id
        AND daily_responses.ai_review IS NOT NULL
        AND daily_responses.ai_review <> '{}'::jsonb
    SQL
  end

  def down
    remove_column :daily_responses, :review_provider
  end

  private

  def other_provider_recorded
    current_prefix = "CASE users.provider #{MODEL_PREFIXES.map { |provider, prefix| "WHEN '#{provider}' THEN '#{prefix}'" }.join(' ')} END"
    known_prefix = MODEL_PREFIXES.values.map { |prefix| "api_usages.model LIKE '#{prefix}%'" }.join(" OR ")

    <<~SQL.squish
      EXISTS (SELECT 1 FROM api_usages
              WHERE api_usages.user_id = users.id
                AND (#{known_prefix})
                AND api_usages.model NOT LIKE #{current_prefix} || '%')
    SQL
  end
end
