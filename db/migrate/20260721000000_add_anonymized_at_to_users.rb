class AddAnonymizedAtToUsers < ActiveRecord::Migration[8.0]
  def change
    # Unindexed on purpose: users holds a handful of team members, so scanning it costs nothing.
    add_column :users, :anonymized_at, :datetime
  end
end
