module LearningTrack
  ON = "junior".freeze
  OFF = "none".freeze
  VALUES = [ ON, OFF ].freeze

  START_LEVEL = "junior".freeze
  GRADUATED_LEVEL = "senior".freeze
  LEVELS = [ START_LEVEL, GRADUATED_LEVEL ].freeze

  # Provisional: confirm this falls slightly after deployment before merging.
  # An earlier cutoff would ask accounts created under the old code to join;
  # a later one only gives accounts in the gap the regular experience.
  INTRODUCED_AT = Time.utc(2026, 10, 9, 18).freeze

  def self.preset_levels
    ExerciseSection.keys.index_with { START_LEVEL }
  end
end
