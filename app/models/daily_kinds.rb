# Design notes: docs/decisions/daily-kinds.md
class DailyKinds
  DEFAULT = ExerciseSection.default_daily.freeze

  COUNT = DEFAULT.size

  FEWEST = 1

  MOST = ExerciseSection::MAX_SECTIONS

  def self.for(user) = held(user.daily_section_kinds, user.daily_section_count)

  def self.pair(user) = pair_of(user.daily_section_kinds)

  def self.pair_of(keys) = normalize(keys).first(COUNT)

  # A fixed setting holds that many places; Automatic holds the pair and lets the gate grow the day.
  def self.held(keys, setting) = normalize(keys).first((setting || COUNT).clamp(FEWEST, MOST))

  def self.shared_pair(kinds) = kinds.size < COUNT ? [] : kinds.first(COUNT)

  # A row planned before plan_notes carried the pair was planned with the default one.
  def self.recorded(plan_notes)
    return DEFAULT unless plan_notes.key?("daily_kinds")

    Array(plan_notes["daily_kinds"]).filter_map { |key| ExerciseSection.find(key) }.uniq.freeze
  end

  def self.normalize(keys)
    kept  = Array(keys).first(MOST).each_with_object([]) { |key, list| list << fitting(ExerciseSection.find(key), list) }
    pair  = kept.first(COUNT) + [ nil ] * (COUNT - kept.size).clamp(0, COUNT)
    spare = DEFAULT - pair
    pair  = pair.map { |kind| kind || spare.shift }

    (pair + (kept.drop(COUNT).compact - pair)).freeze
  end

  def self.problems_with(keys)
    return [ "must be a list" ] unless keys.is_a?(Array)
    return [] if keys.empty?
    return [] if keys.all?(String) && (COUNT..MOST).cover?(keys.size) && normalize(keys).map(&:key) == keys

    [ "must name #{COUNT} to #{MOST} different section kinds, at most one of them from #{ExerciseSection.fourths.map(&:key).join(", ")}" ]
  end

  def self.place?(place) = place.is_a?(Integer) && (0...COUNT).cover?(place)

  def self.stored(keys) = keys == DEFAULT.map(&:key) ? [] : keys

  def self.conflict(kind, others)
    return :repeat if others.include?(kind)

    :second_fourth if kind.fourth? && others.compact.any?(&:fourth?)
  end

  def self.fitting(kind, placed)
    return nil if kind.nil? || conflict(kind, placed)

    kind
  end
  private_class_method :fitting
end
