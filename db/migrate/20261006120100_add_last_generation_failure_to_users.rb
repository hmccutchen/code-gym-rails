# The failure class, provider, time and requested wait of the last generation
# that failed, so the sentence is written when the page is read, in the user's
# zone and against the clock, rather than frozen at write time. The provider
# is stored because the user can switch keys before reading, and the wait
# because a short limit's reset is the provider's number. last_generation_error
# stays for messages that are not provider failures and for rows written
# before this.
class AddLastGenerationFailureToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :last_generation_failure, :string
    add_column :users, :last_generation_failure_provider, :string
    add_column :users, :last_generation_failed_at, :datetime
    add_column :users, :last_generation_retry_after, :integer
  end
end
