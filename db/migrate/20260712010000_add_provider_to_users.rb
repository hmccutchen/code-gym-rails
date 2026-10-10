# Detected from the key's prefix at save time; nil until the user saves a key.
class AddProviderToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :provider, :string
  end
end
