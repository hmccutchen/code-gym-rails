# The failure class and time of the last generation that failed, so the
# sentence is written when the page is read, in the user's zone and against
# the clock, rather than frozen at write time. last_generation_error stays for
# messages that are not provider failures and for rows written before this.
class AddLastGenerationFailureToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :last_generation_failure, :string
    add_column :users, :last_generation_failed_at, :datetime
  end
end
