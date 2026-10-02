# Nullable with no default and no backfill: nil is Automatic, so every
# existing account reads Automatic, including one that had turned adaptive
# sizing off.
class AddDailySectionCountToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :daily_section_count, :integer
  end
end
