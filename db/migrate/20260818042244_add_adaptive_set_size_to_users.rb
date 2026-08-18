class AddAdaptiveSetSizeToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :adaptive_set_size, :boolean, default: true, null: false
  end
end
