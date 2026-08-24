class RenameLoginTokenColumns < ActiveRecord::Migration[8.1]
  def change
    remove_index  :users, :login_token_digest
    remove_column :users, :login_token_digest, :string

    rename_column :users, :login_token_sent_at, :login_code_sent_at
  end
end
