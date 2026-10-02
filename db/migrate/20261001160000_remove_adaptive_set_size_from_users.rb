# Safe only once the Daily sections release, which stopped reading the column
# through ignored_columns, is serving every process.
class RemoveAdaptiveSetSizeFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :adaptive_set_size, :boolean, default: true, null: false
  end
end
