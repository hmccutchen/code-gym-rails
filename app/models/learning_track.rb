module LearningTrack
  ON = "junior".freeze
  OFF = "none".freeze
  VALUES = [ ON, OFF ].freeze

  START_LEVEL = "junior".freeze
  START_SKILL_LEVEL = "junior".freeze
  GRADUATED_LEVEL = "senior".freeze
  LEVELS = [ START_LEVEL, GRADUATED_LEVEL ].freeze

  def self.preset_levels
    ExerciseSection.keys.index_with { START_LEVEL }
  end
end
