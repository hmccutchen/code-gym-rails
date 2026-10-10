# No default or backfill: nil is Automatic, so every existing account reads Automatic.
class AddDailySectionCountToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :daily_section_count, :integer
  end
end
