require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261015130000_seed_level_suggestion_cutoffs.rb")
require migration_path.to_s

RSpec.describe SeedLevelSuggestionCutoffs do
  let(:today) { Time.now.utc.to_date.iso8601 }

  def migrate
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
  end

  def seeded(level)
    { "level" => level, "through" => today }
  end

  it "records every kind at its current rung, from its target or else the skill level" do
    user = User.create!(email: "seed@example.com", name: "Seed", skill_level: "mid_level")
    user.update_columns(section_kind_levels: { "pattern" => "senior" })

    migrate

    cutoffs = user.reload.level_suggestion_cutoffs
    expect(cutoffs.keys).to match_array(ExerciseSection.keys)
    expect(cutoffs["pattern"]).to eq(seeded("senior"))
    expect(cutoffs["code_review"]).to eq(seeded("mid_level"))
  end

  it "keeps a cutoff the account already has" do
    user = User.create!(email: "kept@example.com", name: "Kept")
    earlier = { "level" => "junior", "through" => "2026-10-10" }
    user.update_columns(level_suggestion_cutoffs: { "code_review" => earlier })

    migrate

    cutoffs = user.reload.level_suggestion_cutoffs
    expect(cutoffs["code_review"]).to eq(earlier)
    expect(cutoffs["pattern"]).to eq(seeded("junior"))
  end

  it "records nothing for a kind at principal engineer, which no suggestion leaves" do
    user = User.create!(email: "principal@example.com", name: "Principal", skill_level: "principal_engineer")
    user.update_columns(section_kind_levels: { "pattern" => "junior" })

    migrate

    expect(user.reload.level_suggestion_cutoffs).to eq("pattern" => seeded("junior"))
  end

  it "reads an unknown stored target as no target" do
    user = User.create!(email: "odd@example.com", name: "Odd", skill_level: "senior")
    user.update_columns(section_kind_levels: { "pattern" => "expert" })

    migrate

    expect(user.reload.level_suggestion_cutoffs["pattern"]).to eq(seeded("senior"))
  end

  it "hides results from before the migration at the seeded rung" do
    user = User.create!(email: "hidden@example.com", name: "Hidden")

    migrate

    expect(LevelSuggestion.cutoff_date(user.reload.level_suggestion_cutoffs["code_review"], level: "junior"))
      .to eq(Date.iso8601(today))
  end
end
