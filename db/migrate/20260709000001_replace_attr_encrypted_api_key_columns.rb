# The scaffold created attr_encrypted-style columns (encrypted_api_key +
# encrypted_api_key_iv), but the model uses Rails ActiveRecord Encryption
# (`encrypts :api_key`), which stores its ciphertext in a column named api_key.
# The old columns were never written by anything; api_key assignments landed in
# a virtual attribute and were silently lost on save.
class ReplaceAttrEncryptedApiKeyColumns < ActiveRecord::Migration[8.0]
  def change
    remove_column :users, :encrypted_api_key, :string
    remove_column :users, :encrypted_api_key_iv, :string
    # text, not string: AR Encryption payloads (base64 ciphertext + metadata)
    # comfortably exceed short varchar assumptions.
    add_column :users, :api_key, :text
  end
end
