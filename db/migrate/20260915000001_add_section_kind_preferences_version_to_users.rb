class AddSectionKindPreferencesVersionToUsers < ActiveRecord::Migration[8.0]
  # A counter rather than a timestamp: this value round-trips through JSON to
  # the browser and back, and a timestamp loses precision on the way, which
  # would refuse a save that was never stale.
  def change
    add_column :users, :section_kind_preferences_version, :integer, default: 0, null: false
  end
end
