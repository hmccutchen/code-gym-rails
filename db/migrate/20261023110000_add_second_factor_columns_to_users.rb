# The otp_* columns may hold a secret from the Devise enrollment, which the authenticator app may no longer show.
class AddSecondFactorColumnsToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.datetime :two_factor_enabled_at
      t.datetime :second_factor_challenge_at
      t.integer  :second_factor_challenge_failures, null: false, default: 0
      t.integer  :second_factor_failures, null: false, default: 0
      t.datetime :second_factor_failures_since
      t.datetime :sessions_valid_after
      t.remove   :otp_required_for_login, type: :boolean, null: false, default: false
    end

    reversible do |direction|
      direction.up { execute "UPDATE users SET otp_secret = NULL, consumed_timestep = NULL, otp_backup_codes = NULL" }
    end
  end
end
