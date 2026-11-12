# Reasoning in docs/code-notes/db/migrate/20261112140000_repeat_unopened_set_pause_fills.md.
class RepeatUnopenedSetPauseFills < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET generation_pause_source = 'manual' WHERE paused_generation_at IS NOT NULL AND generation_pause_source IS NULL"
    execute "UPDATE users SET generation_pause_source = NULL WHERE paused_generation_at IS NULL AND generation_pause_source IS NOT NULL"
    execute "UPDATE daily_exercises SET opened_at = created_at WHERE opened_at IS NULL"
  end

  def down; end
end
