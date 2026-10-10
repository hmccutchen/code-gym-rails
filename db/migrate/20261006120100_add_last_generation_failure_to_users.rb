# Stored as data so the sentence is written when read, in the user's zone and against the clock.
class AddLastGenerationFailureToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :last_generation_failure, :string
    add_column :users, :last_generation_failure_provider, :string
    add_column :users, :last_generation_failed_at, :datetime
    add_column :users, :last_generation_retry_after, :integer
  end
end
