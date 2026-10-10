# Only a SHA-256 digest is stored: a 130-bit random code needs no slow hash.
class CreateInviteCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :invite_codes do |t|
      t.string  :code_digest, null: false
      t.string  :label
      t.integer :seats, null: false
      t.integer :redeemed_count, null: false, default: 0
      t.datetime :expires_at, null: false
      t.integer :trial_days, null: false
      t.integer :daily_request_cap
      t.timestamps
    end

    add_index :invite_codes, :code_digest, unique: true
  end
end
