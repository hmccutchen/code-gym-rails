# Design notes: docs/decisions/daily-kinds.md
class DailyKinds
  DEFAULT = ExerciseSection.default_daily.freeze

  COUNT = DEFAULT.size

  def self.for(user)
    normalize(user.daily_section_kinds)
  end

  # A row planned before plan_notes carried the pair was planned with the default one.
  def self.recorded(plan_notes)
    return DEFAULT unless plan_notes.key?("daily_kinds")

    Array(plan_notes["daily_kinds"]).filter_map { |key| ExerciseSection.find(key) }.uniq.freeze
  end

  def self.normalize(keys)
    kept  = Array(keys).first(COUNT).each_with_object([]) { |key, list| list << fitting(ExerciseSection.find(key), list) }
    kept += [ nil ] * (COUNT - kept.size)
    spare = DEFAULT - kept

    kept.map { |kind| kind || spare.shift }.freeze
  end

  def self.problems_with(keys)
    return [ "must be a list" ] unless keys.is_a?(Array)
    return [] if keys.empty?
    return [] if keys.all?(String) && keys.size == COUNT && normalize(keys).map(&:key) == keys

    [ "must name #{COUNT} different section kinds, at most one of them a fourth-section kind" ]
  end

  def self.fitting(kind, placed)
    return nil if kind.nil? || placed.include?(kind)
    return nil if kind.fourth? && placed.compact.any?(&:fourth?)

    kind
  end
  private_class_method :fitting
end
