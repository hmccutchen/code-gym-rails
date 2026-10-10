# Invalid levels read as unset and orphaned locks as unlocked, so a console write can't suppress easing.
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

  # An out-of-scale skill level reads as the lowest rung instead of aborting generation after a billed call.
  def rung_for(kind, skill_level:)
    level_for(kind) || (LEVELS.include?(skill_level) ? skill_level : LEVELS.first)
  end

  def locked?(kind)
    targeted?(kind) && @locked.include?(kind.key)
  end

  def targeted_kinds
    ExerciseSection.all.select { |kind| targeted?(kind) }
  end
end
