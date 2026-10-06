# An invite code admits one account per seat. A code with a provider starts a
# trial on a house key for that provider; one without is a plain join code
# for a teammate who brings their own key. Only a digest is stored: a
# 26-character base32 code carries 130 bits, so a SHA-256 lookup is enough
# and no slow hash is needed.
class CreateInviteCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :invite_codes do |t|
      t.string  :code_digest, null: false
      t.string  :label
      t.string  :provider
      t.integer :seats, null: false
      t.integer :redeemed_count, null: false, default: 0
      t.datetime :expires_at, null: false
      t.integer :trial_days
      t.integer :daily_request_cap
      t.timestamps
    end

    add_index :invite_codes, :code_digest, unique: true
  end
end
