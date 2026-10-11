class AddMidLevelRung < ActiveRecord::Migration[8.1]
  LEGACY_SKILL_LEVELS = { "beginner" => "junior", "developing" => "junior", "solid" => "senior", "strong" => "principal_engineer" }.freeze

  def up
    add_column :concept_references, :ladder_mid_level, :text
    change_column_default :users, :skill_level, from: "developing", to: "junior"
    LEGACY_SKILL_LEVELS.each { |legacy, level| execute("UPDATE users SET skill_level = #{quote(level)} WHERE skill_level = #{quote(legacy)}") }
  end

  def down
    change_column_default :users, :skill_level, from: "junior", to: "developing"
    execute("UPDATE users SET skill_level = 'junior' WHERE skill_level = 'mid_level'")
    remove_column :concept_references, :ladder_mid_level
  end

  private

  def quote(value) = connection.quote(value)
end
