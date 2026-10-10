class AddSectionKindPreferencesToUsers < ActiveRecord::Migration[8.0]
  # Two columns: a low weight and an exclusion are different actions, which the UI keeps apart.
  def change
    add_column :users, :section_kind_weights,   :jsonb, default: {}, null: false
    add_column :users, :excluded_section_kinds, :jsonb, default: [], null: false
  end
end
