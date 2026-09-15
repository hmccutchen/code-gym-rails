# A user's stated bias over which rotating kinds they see, as plain values.
# SectionRotation takes one of these rather than a User — the same shape
# SectionCount's `adaptive:` uses — so the rotation's specs need no database.
#
# Total by construction: a stored value outside MULTIPLIERS reads as the
# default rather than reaching WeightedRoll, where a zero would make a kind
# unpickable below starvation and a negative would corrupt every other kind's
# share of the roll.
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
