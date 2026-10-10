# Nullable because older rows never recorded these; provider is backfilled since each model name implies it.
class AddOutcomeToApiUsages < ActiveRecord::Migration[8.1]
  def up
    add_column :api_usages, :provider, :string
    add_column :api_usages, :http_status, :integer
    add_column :api_usages, :failure, :string
    add_column :api_usages, :quota_id, :string
    add_column :api_usages, :house_key, :boolean, default: false, null: false
    add_index :api_usages, [ :provider, :house_key, :created_at ]

    execute <<~SQL
      UPDATE api_usages SET provider = CASE
        WHEN model LIKE 'claude%' THEN 'anthropic'
        WHEN model LIKE 'gemini%' THEN 'gemini'
        WHEN model LIKE 'gpt%'    THEN 'openai'
        WHEN model LIKE 'fake%'   THEN 'fake'
      END
      WHERE model IS NOT NULL
    SQL
  end

  def down
    remove_index :api_usages, [ :provider, :house_key, :created_at ]
    remove_column :api_usages, :house_key
    remove_column :api_usages, :quota_id
    remove_column :api_usages, :failure
    remove_column :api_usages, :http_status
    remove_column :api_usages, :provider
  end
end
