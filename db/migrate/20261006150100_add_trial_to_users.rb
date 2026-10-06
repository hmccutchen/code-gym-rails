# Which code admitted the account, and the trial it started, if any. There is
# no trial flag: a trial_ends_at is the fact, and an account with a code and
# no trial dates joined on a plain join code or has not yet consented.
class AddTrialToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :invite_code, null: true, foreign_key: true
    add_column :users, :trial_started_at, :datetime
    add_column :users, :trial_ends_at, :datetime
    add_column :users, :trial_consented_at, :datetime
  end
end
