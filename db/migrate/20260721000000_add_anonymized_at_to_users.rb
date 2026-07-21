class AddAnonymizedAtToUsers < ActiveRecord::Migration[8.0]
  def change
    # Nullable and unindexed on purpose: `users` holds a handful of team
    # members, and every query against it is already a primary-key or
    # unique-email lookup.
    add_column :users, :anonymized_at, :datetime
  end
end
