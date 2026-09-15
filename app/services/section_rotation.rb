# Which optional slots today's set fills, and with which kind. Pure: takes
# history, a count, and the user's preferences, and returns rolled symbols.
#
# The count is a hard cap decided by SectionCount. Starvation chooses which
# slots fill it, never how many — a starved kind whose slot did not make the
# cut waits for a day with room.
class SectionRotation
  LOOKBACK         = 20
  STARVATION_LIMIT = 10

  # code_review is the only mandatory slot; everything else ExerciseSection
  # names is fair game for rotation, so a slot added there needs no matching
  # edit here.
  OPTIONAL_SLOTS       = (ExerciseSection.slots.keys - [ :code_review ]).freeze
  MANDATORY_SLOT_COUNT = ExerciseSection.slot_count - OPTIONAL_SLOTS.size

  def self.for(history, count:, preferences: KindPreferences.none)
    recent    = history.first(LOOKBACK)
    available = (count - MANDATORY_SLOT_COUNT).clamp(0, OPTIONAL_SLOTS.size)

    filled = OPTIONAL_SLOTS
      .sort_by { |slot| [ -slot_staleness(slot, recent, preferences), OPTIONAL_SLOTS.index(slot) ] }
      .first(available)

    OPTIONAL_SLOTS.index_with { |slot| filled.include?(slot) ? pick_kind(slot, recent, preferences) : nil }
  end

  # Exclusion removes a kind from the pool everywhere the pool is read — the
  # roll, the starvation check, and the slot's own staleness. A weight never
  # does; it only leans the roll. That asymmetry is the point: a slot ranked on
  # a kind that can never fill it would win a scarce spot on false strength.
  #
  # User validation refuses an exclusion that would empty a slot, so the
  # fallback below is for a row that got past it. Ignoring an impossible
  # preference beats a day that silently drops a section.
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

  # A starved kind is taken outright rather than rolled for, and ties among
  # equally stale starved kinds drain in registry order: scheduling one resets
  # its staleness, so a fixed order empties the pool one per day and bounds the
  # worst-case wait at the pool size, which a coin flip among equals would not.
  # Below starvation, equally stale kinds are separated only by the user's
  # stated multiplier, and an unbiased tie still breaks randomly.
  #
  # The user's multiplier reaches the roll and nothing else. Starvation returns
  # above it, so no weight can hold a kind out of rotation indefinitely — the
  # failure mode staleness-weighting replaced.
  def self.pick_kind(slot, recent, preferences)
    kinds   = eligible(slot, preferences)
    starved = kinds.select { |kind| staleness(kind, recent) > STARVATION_LIMIT }

    return most_stale(starved, recent).key.to_sym if starved.any?

    # Weighted by staleness times the user's stated bias — no base-weights table
    # multiplied in. No kind here is the baseline the others vary from, so
    # recency and stated preference are the only things separating them
    # (DailyPlan's old fixed third/fourth weight tables were uniform for the
    # same reason, before this replaced them).
    weights = kinds.index_with { |kind| staleness(kind, recent) * preferences.multiplier_for(kind) }
    WeightedRoll.pick(weights).key.to_sym
  end
  private_class_method :pick_kind

  def self.most_stale(kinds, recent)
    kinds.max_by { |kind| [ staleness(kind, recent), -ExerciseSection.all.index(kind) ] }
  end
  private_class_method :most_stale
end
