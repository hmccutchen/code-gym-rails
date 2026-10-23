# Rotating the encryption keys leaves stored keys undecryptable, so they are cleared in SQL rather than read through the model.
class ClearProviderKeysAndPushSubscriptions < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE users
      SET api_keys = NULL,
          provider = CASE WHEN trial_ends_at IS NULL THEN NULL ELSE provider END
      WHERE api_keys IS NOT NULL
    SQL
    execute "DELETE FROM push_subscriptions"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
