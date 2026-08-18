# Which optional slots today's set fills, and with which kind. Pure: takes
# history and a count, returns rolled symbols.
#
# The count is a hard cap decided by SectionCount. Starvation chooses which
# slots fill it, never how many — a starved kind whose slot did not make the
# cut waits for a day with room.
class SectionRotation
  LOOKBACK         = 20
  STARVATION_LIMIT = 10

  OPTIONAL_SLOTS = %i[pattern third fourth].freeze

  def self.for(history, count:)
    recent    = history.first(LOOKBACK)
    available = count - 1

    filled = OPTIONAL_SLOTS
      .sort_by { |slot| -slot_staleness(slot, recent) }
      .first(available)

    OPTIONAL_SLOTS.index_with { |slot| filled.include?(slot) ? pick_kind(slot, recent) : nil }
  end

  def self.eligible(slot)
    ExerciseSection.slots.fetch(slot)
  end
  private_class_method :eligible

  def self.slot_staleness(slot, recent)
    eligible(slot).map { |kind| staleness(kind, recent) }.max
  end
  private_class_method :slot_staleness

  def self.staleness(kind, recent)
    seen = recent.index { |entry| entry.section_keys.include?(kind.key) }

    seen ? seen + 1 : LOOKBACK + 1
  end
  private_class_method :staleness

  # A starved kind is taken outright rather than rolled for. Ties among equally
  # stale kinds drain in registry order: scheduling one resets its staleness, so
  # a fixed order empties the pool one per day and bounds the worst-case wait at
  # the pool size, which a coin flip among equals would not.
  def self.pick_kind(slot, recent)
    kinds   = eligible(slot)
    starved = kinds.select { |kind| staleness(kind, recent) > STARVATION_LIMIT }

    return most_stale(starved, recent).key.to_sym if starved.any?

    # Weighted purely by staleness — no base-weights table multiplied in. No
    # kind here is the baseline the others vary from, so recency is the only
    # thing separating them (DailyPlan's old fixed third/fourth weight tables
    # were uniform for the same reason, before this replaced them).
    weights = kinds.index_with { |kind| staleness(kind, recent) }
    WeightedRoll.pick(weights).key.to_sym
  end
  private_class_method :pick_kind

  def self.most_stale(kinds, recent)
    kinds.max_by { |kind| [ staleness(kind, recent), -ExerciseSection.all.index(kind) ] }
  end
  private_class_method :most_stale
end
