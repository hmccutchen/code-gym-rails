require "rails_helper"

RSpec.describe TrackChange do
  def change(levels, locked: [], from: "junior", to: "mid_level")
    described_class.new(levels: levels, locked: locked, from: from, to: to)
  end

  it "retains explicit targets at the old, new and other rungs, with their locks" do
    levels = { "code_review" => "junior", "pattern" => "mid_level", "challenge" => "senior" }.freeze
    [ [], levels.keys ].each do |locked|
      result = change(levels, locked: locked.freeze)

      expect(result.retained).to match_array(levels.map { |kind, level| { kind: kind, level: level, locked: locked.include?(kind) } })
      expect(result.changed.map { |move| move[:kind] }).to match_array(ExerciseSection.keys - levels.keys)
      expect(result.changed).to all(include(from: "junior", to: "mid_level"))
    end
  end

  it "uses all registered kinds and preserves targets on downward and principal moves" do
    levels = { "pattern" => "mid_level", "architecture" => "principal_engineer" }
    [ [ "senior", "junior" ], [ "senior", "principal_engineer" ] ].each do |from, to|
      result = change(levels, from: from, to: to)
      expect(result.changed).to match_array((ExerciseSection.keys - levels.keys).map { |kind| { kind: kind, from: from, to: to } })
      expect(result.retained.map { |target| target[:level] }).to match_array(levels.values)
    end
  end

  it "distinguishes a baseline-only change from a track already saved" do
    targets = ExerciseSection.keys.index_with { "junior" }
    result = change(targets)

    expect(result.changed).to be_empty
    expect(result).not_to be_already_saved
    expect(change(targets, to: "junior")).to be_already_saved
  end

  it "uses KindDifficulty's normalization for historical invalid targets and orphaned locks" do
    result = change({ "pattern" => "unknown" }, locked: [ "pattern" ])

    expect(result.retained).to be_empty
    expect(result.changed).to include(kind: "pattern", from: "junior", to: "mid_level")
  end
end
