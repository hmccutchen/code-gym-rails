# DaySize fixes the count; starvation picks which slots fill it, never how many.
class SectionRotation
  LOOKBACK         = 20
  STARVATION_LIMIT = 10

  def self.for(history, count:, daily:, preferences: KindPreferences.none)
    recent    = history.first(LOOKBACK)
    slots     = ExerciseSection.optional_slots(daily: daily)
    available = (count - daily.size).clamp(0, slots.size)

    filled = slots.keys
      .sort_by { |slot| [ -slot_staleness(slots[slot], recent, preferences), slots.keys.index(slot) ] }
      .first(available)

    slots.to_h { |slot, kinds| [ slot, filled.include?(slot) ? pick_kind(kinds, recent, preferences) : nil ] }
  end

  # Only exclusion narrows the pool, staleness included; a weight just leans the roll. Empty pools fall back to all.
  def self.eligible(kinds, preferences)
    kinds.reject { |kind| preferences.excluded?(kind) }.presence || kinds
  end
  private_class_method :eligible

  def self.slot_staleness(kinds, recent, preferences)
    eligible(kinds, preferences).map { |kind| staleness(kind, recent) }.max
  end
  private_class_method :slot_staleness

  def self.staleness(kind, recent)
    seen = recent.index { |entry| entry.section_keys.include?(kind.key) }

    seen ? seen + 1 : LOOKBACK + 1
  end
  private_class_method :staleness

  # Starved kinds drain in registry order to bound the wait; weights reach only the roll, so none can starve a kind.
  def self.pick_kind(slot_kinds, recent, preferences)
    kinds   = eligible(slot_kinds, preferences)
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
