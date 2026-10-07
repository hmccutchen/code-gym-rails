# An invite code starts trials on a house key: how many accounts it admits,
# by when, for how many days and at how many calls a day. The person picks
# the provider when they redeem it. Only a digest is stored: a 26-character
# base32 code carries 130 bits, so a SHA-256 lookup is enough and no slow
# hash is needed.
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
