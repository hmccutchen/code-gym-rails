# A usage row now records the call's outcome as well as its tokens: the
# provider, the HTTP status, a failure code for a call that returned nothing
# usable, the provider's quota identifier on a 429, and whether the call was
# billed to a house key. Nullable because rows written before this did not
# record them; the provider is backfilled because every model name names its
# provider, so that one is known rather than guessed.
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
