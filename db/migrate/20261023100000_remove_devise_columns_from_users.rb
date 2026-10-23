class RemoveDeviseColumnsFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_index  :users, :reset_password_token, unique: true
    remove_index  :users, :confirmation_token,   unique: true
    remove_column :users, :encrypted_password,     :string, null: false, default: ""
    remove_column :users, :reset_password_token,   :string
    remove_column :users, :reset_password_sent_at, :datetime
    remove_column :users, :confirmation_token,     :string
    remove_column :users, :confirmed_at,           :datetime
    remove_column :users, :confirmation_sent_at,   :datetime
  end
end
