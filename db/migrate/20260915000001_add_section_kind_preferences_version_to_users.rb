class AddSectionKindPreferencesVersionToUsers < ActiveRecord::Migration[8.0]
  # A counter, because a timestamp loses precision through JSON and would refuse a save that was never stale.
  def change
    add_column :users, :section_kind_preferences_version, :integer, default: 0, null: false
  end
end
