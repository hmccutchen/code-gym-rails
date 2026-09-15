class AddSectionKindDifficultyToUsers < ActiveRecord::Migration[8.0]
  # Two columns rather than one blob, for the reason the weights migration gives:
  # a target and a lock are different actions.
  def change
    add_column :users, :section_kind_levels,  :jsonb, default: {}, null: false
    add_column :users, :locked_section_kinds, :jsonb, default: [], null: false
  end
end
