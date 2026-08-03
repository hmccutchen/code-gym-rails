class AddLoginCodeToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :login_code_digest, :string
    add_column :users, :login_code_attempts, :integer, default: 0, null: false
  end
end
