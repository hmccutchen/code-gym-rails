# Accounts that exist already proved their address with an emailed code, so they start confirmed.
class AddDeviseAndTwoFactorToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.string   :encrypted_password, null: false, default: ""
      t.string   :reset_password_token
      t.datetime :reset_password_sent_at
      t.string   :confirmation_token
      t.datetime :confirmed_at
      t.datetime :confirmation_sent_at
      t.string   :otp_secret
      t.integer  :consumed_timestep
      t.boolean  :otp_required_for_login, null: false, default: false
      t.string   :otp_backup_codes, array: true
    end

    add_index :users, :reset_password_token, unique: true
    add_index :users, :confirmation_token,   unique: true

    reversible do |direction|
      direction.up { execute "UPDATE users SET confirmed_at = created_at" }
    end
  end
end
