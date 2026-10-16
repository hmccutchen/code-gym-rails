# Design notes: docs/decisions/daily-kinds.md
class DailyKinds
  DEFAULT = ExerciseSection.all.select(&:default_daily?).freeze

  COUNT = DEFAULT.size

  def self.for(user)
    normalize(user.daily_section_kinds)
  end

  # A row planned before plan_notes carried the pair was planned with the default one.
  def self.recorded(plan_notes)
    plan_notes.key?("daily_kinds") ? normalize(plan_notes["daily_kinds"]) : DEFAULT
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
    return [ "must name exactly #{COUNT} section kinds" ] unless keys.size == COUNT
    return [ "must name known section kinds" ] unless keys.all? { |key| key.is_a?(String) && ExerciseSection.find(key) }
    return [ "must not repeat a section kind" ] unless keys.uniq.size == COUNT
    return [ "may hold at most one fourth-section kind" ] if keys.count { |key| ExerciseSection.find(key).fourth? } > 1

    []
  end

  def self.fitting(kind, placed)
    return nil if kind.nil? || placed.include?(kind)
    return nil if kind.fourth? && placed.compact.any?(&:fourth?)

    kind
  end
  private_class_method :fitting
end
