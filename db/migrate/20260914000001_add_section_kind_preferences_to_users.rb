class AddSectionKindPreferencesToUsers < ActiveRecord::Migration[8.0]
  # Two columns rather than one nested blob: a low weight and an exclusion are
  # different actions, and storing them as two fields of one fact is the
  # conflation the UI copy exists to prevent, reintroduced underneath it.
  def change
    add_column :users, :section_kind_weights,   :jsonb, default: {}, null: false
    add_column :users, :excluded_section_kinds, :jsonb, default: [], null: false
  end
end
