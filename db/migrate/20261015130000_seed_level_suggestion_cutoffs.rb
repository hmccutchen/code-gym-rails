# Reasoning in docs/code-notes/db/migrate/20261015130000_seed_level_suggestion_cutoffs.md.
class SeedLevelSuggestionCutoffs < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE users SET level_suggestion_cutoffs = #{seeded_cutoffs} || level_suggestion_cutoffs
    SQL
  end

  # Irreversible: a seeded entry looks like any recorded cutoff, so nothing is safe to undo.
  def down; end

  private

  def seeded_cutoffs
    pairs = ExerciseSection.keys.map { |key| "#{quote(key)}, #{cutoff_sql(rung_sql(key))}" }
    "jsonb_strip_nulls(jsonb_build_object(#{pairs.join(', ')}))"
  end

  def cutoff_sql(rung)
    "CASE WHEN #{rung} IN (#{quote_all(LevelSuggestion::LADDER)}) " \
      "THEN jsonb_build_object('level', #{rung}, 'through', (now() AT TIME ZONE 'UTC')::date::text) END"
  end

  def rung_sql(key)
    target = "section_kind_levels->>#{quote(key)}"
    "COALESCE(CASE WHEN #{target} IN (#{quote_all(KindDifficulty::LEVELS)}) THEN #{target} END, skill_level)"
  end

  def quote_all(values)
    values.map { |value| quote(value) }.join(", ")
  end

  def quote(value)
    connection.quote(value)
  end
end
