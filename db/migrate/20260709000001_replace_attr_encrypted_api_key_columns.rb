# `encrypts :api_key` stores ciphertext in api_key; nothing ever wrote the attr_encrypted columns.
class ReplaceAttrEncryptedApiKeyColumns < ActiveRecord::Migration[8.0]
  def change
    remove_column :users, :encrypted_api_key, :string
    remove_column :users, :encrypted_api_key_iv, :string
    # text, not string: encrypted payloads exceed short varchar limits.
    add_column :users, :api_key, :text
  end
end
