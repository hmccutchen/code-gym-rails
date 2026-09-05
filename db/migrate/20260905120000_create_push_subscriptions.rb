class CreatePushSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :push_subscriptions do |t|
      t.references :user, null: false, foreign_key: true
      # The push service's per-install URL. Unique because re-subscribing on
      # launch must refresh the existing row rather than accumulate a second
      # one for the same browser.
      t.string :endpoint, null: false
      t.string :p256dh_key, null: false
      t.string :auth_key, null: false
      t.datetime :last_delivered_at
      t.timestamps
    end

    add_index :push_subscriptions, :endpoint, unique: true
  end
end
