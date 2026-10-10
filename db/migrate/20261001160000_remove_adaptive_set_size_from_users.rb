# Safe only once the release that stopped reading this column is serving every process.
class RemoveAdaptiveSetSizeFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :adaptive_set_size, :boolean, default: true, null: false
  end
end
