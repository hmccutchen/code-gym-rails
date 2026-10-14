# Safe only once the release that stopped reading this column is serving every process.
class RemoveApiKeyFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :api_key, :text
  end
end
