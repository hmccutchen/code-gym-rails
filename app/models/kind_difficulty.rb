# A user's stated difficulty target and lock per section kind, as plain values —
# the shape KindPreferences gives SectionRotation, so prompt specs need no
# database.
#
# Total by construction: a level outside LEVELS reads as unset, and a lock on a
# kind with no valid level reads as unlocked. A lock orphaned by a console write
# can therefore never suppress easing the user did not validly choose.
class KindDifficulty
  LEVELS = %w[junior senior principal_engineer].freeze

  LEVEL_DEFINITIONS = {
    "junior"             => "one clearly visible instance of the concept in a small scenario.",
    "senior"             => "the concept alongside a realistic constraint or a second interacting issue, where the right answer depends on reading context.",
    "principal_engineer" => "the concept framed as a decision with costs on both sides at system scale."
  }.freeze

  def self.none
    new(levels: {}, locked: [])
  end

  def self.for(user)
    new(levels: user.section_kind_levels, locked: user.locked_section_kinds)
  end

  def initialize(levels:, locked:)
    @levels = levels
    @locked = locked
  end

  def level_for(kind)
    value = @levels[kind.key]

    LEVELS.include?(value) ? value : nil
  end

  def targeted?(kind)
    !level_for(kind).nil?
  end

  def locked?(kind)
    targeted?(kind) && @locked.include?(kind.key)
  end

  def targeted_kinds
    ExerciseSection.all.select { |kind| targeted?(kind) }
  end
end
