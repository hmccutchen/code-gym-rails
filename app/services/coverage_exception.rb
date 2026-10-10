# At two sections SectionRotation's starvation guarantee has no slot to act on, so a kind could wait forever.
class CoverageException
  # The cap below binds once several kinds are stale; this only sets how soon the first addition comes.
  GAP_WEEKDAYS = 20

  # Calendar weekdays: weekends never count, and a paused stretch counts as the weekdays it spans.
  CAP_WEEKDAYS = 4

  # Longer than SectionRotation::LOOKBACK, where capped staleness ties every slot.
  HISTORY_LIMIT = 120

  OPTIONAL_KINDS = ExerciseSection.all.reject(&:fixed?).freeze

  # check names the retention check a due_check addition was made for, so the plan can tell whether it landed.
  Addition = Data.define(:kind, :reason, :check) do
    def initialize(kind:, reason:, check: nil) = super
  end

  def self.applies_to_day?(count:, fixed:, brake: false)
    fixed.nil? && count <= ExerciseSection.fixed.size && !brake
  end

  # checks are hashes with :concept, :bucket and :overdue_ratio.
  def self.for(today:, count:, fixed:, history:, checks:, preferences:, hosts:, brake: false)
    return nil unless applies_to_day?(count: count, fixed: fixed, brake: brake)
    return nil if capped?(history.coverage_dates, today)

    gaps       = OPTIONAL_KINDS.reject { |kind| preferences.excluded?(kind) }.index_with { |kind| gap(kind, history, today) }
    candidates = gaps.keys.sort_by { |kind| [ -gaps[kind], history.last_seen.key?(kind.key) ? 1 : 0, ExerciseSection.all.index(kind) ] }

    due_check_addition(checks, candidates, hosts) || gap_addition(candidates.first, gaps)
  end

  def self.due_check_addition(checks, candidates, hosts)
    overdue = checks.select { |check| check[:overdue_ratio] >= ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER }

    overdue.sort_by { |check| -check[:overdue_ratio] }.each do |check|
      host = hosts.hosts(candidates, check[:concept], check[:bucket]).first
      return Addition.new(kind: host, reason: :due_check, check: check) if host
    end
    nil
  end
  private_class_method :due_check_addition

  def self.gap_addition(kind, gaps)
    Addition.new(kind: kind, reason: :gap) if kind && gaps[kind] > GAP_WEEKDAYS
  end
  private_class_method :gap_addition

  # The first date whose coverage addition still blocks today's.
  def self.cap_window_start(today)
    weekdays_before(today, CAP_WEEKDAYS)
  end

  def self.capped?(coverage_dates, today)
    coverage_dates.any? { |date| date >= cap_window_start(today) && date < today }
  end

  # A kind never delivered counts from the oldest exercise read; a user with no exercises has no gap.
  def self.gap(kind, history, today)
    from = history.last_seen[kind.key] || history.first_date&.prev_day
    return 0 if from.nil?

    (from.next_day..today).count(&:on_weekday?)
  end
  private_class_method :gap

  def self.weekdays_before(today, count)
    date = today
    while count.positive?
      date = date.prev_day
      count -= 1 if date.on_weekday?
    end
    date
  end
  private_class_method :weekdays_before
end
