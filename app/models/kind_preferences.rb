# Invalid stored multipliers read as the default; a zero or negative would corrupt WeightedRoll.
class KindPreferences
  MULTIPLIERS        = [ 0.25, 0.5, 1.0, 2.0, 4.0 ].freeze
  DEFAULT_MULTIPLIER = 1.0

  def self.none
    new(weights: {}, excluded: [])
  end

  def self.for(user)
    new(weights: user.section_kind_weights, excluded: user.excluded_section_kinds)
  end

  def initialize(weights:, excluded:)
    @weights  = weights
    @excluded = excluded
  end

  def multiplier_for(kind)
    value = @weights[kind.key]

    MULTIPLIERS.include?(value) ? value : DEFAULT_MULTIPLIER
  end

  def excluded?(kind)
    @excluded.include?(kind.key)
  end
end
