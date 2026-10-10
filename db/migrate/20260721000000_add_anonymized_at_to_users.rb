class AddAnonymizedAtToUsers < ActiveRecord::Migration[8.0]
  def change
    # Unindexed on purpose: every users query is already a primary-key or unique-email lookup.
    add_column :users, :anonymized_at, :datetime
  end
end
