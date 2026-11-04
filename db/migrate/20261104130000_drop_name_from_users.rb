class DropNameFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :name, :string, null: false, default: ""
  end
end
