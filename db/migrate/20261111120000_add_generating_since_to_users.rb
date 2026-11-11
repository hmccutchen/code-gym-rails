class AddGeneratingSinceToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :generating_since, :datetime
  end
end
