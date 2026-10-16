class AddDailySectionKindsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :daily_section_kinds, :jsonb, default: [], null: false
  end
end
