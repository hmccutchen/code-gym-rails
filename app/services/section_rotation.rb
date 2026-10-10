# DaySize fixes the count; starvation picks which slots fill it, never how many.
class SectionRotation
  LOOKBACK         = 20
  STARVATION_LIMIT = 10

  MANDATORY_SLOT_COUNT = ExerciseSection.fixed.size
  OPTIONAL_SLOTS       = (ExerciseSection.slots.keys - ExerciseSection.fixed.map { |kind| kind.key.to_sym }).freeze

  def self.for(history, count:, preferences: KindPreferences.none)
    recent    = history.first(LOOKBACK)
    available = (count - MANDATORY_SLOT_COUNT).clamp(0, OPTIONAL_SLOTS.size)

    filled = OPTIONAL_SLOTS
      .sort_by { |slot| [ -slot_staleness(slot, recent, preferences), OPTIONAL_SLOTS.index(slot) ] }
      .first(available)

    OPTIONAL_SLOTS.index_with { |slot| filled.include?(slot) ? pick_kind(slot, recent, preferences) : nil }
  end

  # Only exclusion narrows the pool, staleness included; a weight just leans the roll. Empty pools fall back to all.
  def self.eligible(slot, preferences)
    kinds = ExerciseSection.slots.fetch(slot)

    kinds.reject { |kind| preferences.excluded?(kind) }.presence || kinds
  end
  private_class_method :eligible

  def self.slot_staleness(slot, recent, preferences)
    eligible(slot, preferences).map { |kind| staleness(kind, recent) }.max
  end
  private_class_method :slot_staleness

  def self.staleness(kind, recent)
    seen = recent.index { |entry| entry.section_keys.include?(kind.key) }

    seen ? seen + 1 : LOOKBACK + 1
  end
  private_class_method :staleness

  # Starved kinds drain in registry order to bound the wait; weights reach only the roll, so none can starve a kind.
  def self.pick_kind(slot, recent, preferences)
    kinds   = eligible(slot, preferences)
    starved = kinds.select { |kind| staleness(kind, recent) > STARVATION_LIMIT }

    return most_stale(starved, recent).key.to_sym if starved.any?

    weights = kinds.index_with { |kind| staleness(kind, recent) * preferences.multiplier_for(kind) }
    WeightedRoll.pick(weights).key.to_sym
  end
  private_class_method :pick_kind

  def self.most_stale(kinds, recent)
    kinds.max_by { |kind| [ staleness(kind, recent), -ExerciseSection.all.index(kind) ] }
  end
  private_class_method :most_stale
end
