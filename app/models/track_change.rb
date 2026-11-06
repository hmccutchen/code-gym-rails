# Design notes: docs/code-notes/app/models/track_change.md
class TrackChange
  attr_reader :from, :to, :changed, :retained

  def initialize(levels:, locked:, from:, to:)
    @from = from
    @to = to
    difficulty = KindDifficulty.new(levels: levels, locked: locked)
    before = difficulty.rungs(skill_level: from)
    after = difficulty.rungs(skill_level: to)
    @changed = after.filter_map do |kind, rung|
      { kind: kind, from: before[kind], to: rung } unless before[kind] == rung
    end
    @retained = ExerciseSection.all.filter_map do |kind|
      { kind: kind.key, level: difficulty.level_for(kind), locked: difficulty.locked?(kind) } if difficulty.targeted?(kind)
    end
  end

  def already_saved? = from == to
end
