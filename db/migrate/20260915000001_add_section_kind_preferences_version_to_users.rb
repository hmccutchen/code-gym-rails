class AddSectionKindPreferencesVersionToUsers < ActiveRecord::Migration[8.0]
  # A counter rather than a timestamp: this value round-trips through JSON to
  # the browser and back, and a timestamp loses precision on the way, which
  # would refuse a save that was never stale. It also bumps only when the two
  # preference columns change, so an unrelated write — a name, a time zone —
  # cannot make a pending mix save look stale.
  def change
    add_column :users, :section_kind_preferences_version, :integer, default: 0, null: false
  end
end
