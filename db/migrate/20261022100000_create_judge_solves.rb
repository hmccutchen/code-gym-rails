class CreateJudgeSolves < ActiveRecord::Migration[8.1]
  def change
    create_table :judge_solves do |t|
      t.references :user, foreign_key: true
      t.references :daily_exercise, foreign_key: true, index: false
      t.datetime :set_generated_at
      t.string :source, null: false
      t.string :section, null: false
      t.integer :attempt, null: false
      t.boolean :edit_check, null: false
      t.boolean :shipped, null: false
      t.string :never_shown_reason
      t.boolean :edit_reverted, null: false
      t.string :revert_reason
      t.string :rung, null: false
      t.boolean :locked, null: false
      t.string :concept
      t.string :judge_status
      t.string :judge_pick
      t.string :key_better, null: false
      t.boolean :matched
      t.string :unsolved_reason
      t.string :unsolved_detail
      t.jsonb :judged_section, null: false
      t.string :section_digest, null: false
      t.string :judge_provider, null: false
      t.string :judge_model, null: false
      t.string :draft_model
      t.string :app_revision
      t.string :human_call
      t.text :human_note
      t.datetime :human_called_at
      t.datetime :created_at, null: false

      t.index [ :source, :matched, :created_at ]
      t.index [ :edit_reverted, :created_at ]
      t.index [ :daily_exercise_id, :section, :section_digest ]

      t.check_constraint "source IN ('live', 'replay', 'synthetic')", name: "judge_solves_source"
      t.check_constraint "source = 'synthetic' OR (user_id IS NOT NULL AND daily_exercise_id IS NOT NULL AND set_generated_at IS NOT NULL)",
                         name: "judge_solves_owner_unless_synthetic"
      t.check_constraint "edit_reverted = (revert_reason IS NOT NULL)", name: "judge_solves_revert_reason_iff_reverted"
      t.check_constraint <<~SQL.squish, name: "judge_solves_human_call_by_matched"
        (matched IS NULL AND human_call IS NULL) OR
        (matched IS TRUE AND (human_call IS NULL OR human_call IN ('key_right', 'both_wrong', 'both_defensible'))) OR
        (matched IS FALSE AND (human_call IS NULL OR human_call IN ('key_right', 'judge_right', 'both_defensible')))
      SQL
      t.check_constraint "never_shown_reason IS NULL OR " \
                         "(never_shown_reason IN ('replaced_by_retry', 'section_dropped') AND shipped = FALSE AND source = 'live')",
                         name: "judge_solves_never_shown_reason"
    end
  end
end
