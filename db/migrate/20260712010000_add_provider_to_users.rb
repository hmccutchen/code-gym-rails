# Detected from the API key's prefix at save time (see ApiKeysController) —
# lets AiService.for dispatch to the right provider service without a
# separate settings UI. Nullable: nil until the user has saved a key.
class AddProviderToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :provider, :string
  end
end
