# Whether a two-section Automatic day gains one optional section, and which.
# At two sections no optional slot exists, so the starvation guarantee in
# SectionRotation has nothing to act on, and a kind, or a retention check
# only that kind can host, would otherwise wait indefinitely. Pure: plain
# values in, an Addition or nil out.
class CoverageException
  # A kind unseen for more than this many weekdays (four weeks) is added.
  # The cap below is what binds once several kinds are stale; this only
  # decides how soon the first addition comes after a user settles at two.
  GAP_WEEKDAYS = 20

  # An addition on any of the previous four weekdays blocks another, so a
  # day gains at most one section in any five weekdays. Counted on the
  # calendar: weekends never count, and a paused stretch counts as the
  # weekdays it spans.
  CAP_WEEKDAYS = 4

  # How many past exercises the gaps are read from. Further back than
  # SectionRotation::LOOKBACK, because capped staleness ties every slot once
  # kinds have been unseen that long.
  HISTORY_LIMIT = 120

  OPTIONAL_KINDS = ExerciseSection.all.reject(&:fixed?).freeze

  Addition = Data.define(:kind, :reason)

  def self.applies_to_day?(count:, fixed:, brake: false)
    fixed.nil? && count == SectionCount::FLOOR && !brake
  end

  # `history` is a CoverageException::History. `checks` are the day's
  # waiting retention checks, each a hash with :concept, :bucket and
  # :overdue_ratio. `hosts` answers which kinds can tag a check (DayHosts).
  def self.for(today:, count:, fixed:, history:, checks:, preferences:, hosts:, brake: false)
    return nil unless applies_to_day?(count: count, fixed: fixed, brake: brake)
    return nil if added_recently?(history.coverage_dates, today)

    gaps       = OPTIONAL_KINDS.reject { |kind| preferences.excluded?(kind) }.index_with { |kind| gap(kind, history, today) }
    candidates = gaps.keys.sort_by { |kind| [ -gaps[kind], history.last_seen.key?(kind.key) ? 1 : 0, ExerciseSection.all.index(kind) ] }

    due_check_addition(checks, candidates, hosts) || gap_addition(candidates.first, gaps)
  end

  def self.due_check_addition(checks, candidates, hosts)
    overdue = checks.select { |check| check[:overdue_ratio] >= ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER }

    overdue.sort_by { |check| -check[:overdue_ratio] }.each do |check|
      host = hosts.hosts(candidates, check[:concept], check[:bucket]).first
      return Addition.new(kind: host, reason: :due_check) if host
    end
    nil
  end
  private_class_method :due_check_addition

  def self.gap_addition(kind, gaps)
    Addition.new(kind: kind, reason: :gap) if kind && gaps[kind] > GAP_WEEKDAYS
  end
  private_class_method :gap_addition

  def self.added_recently?(coverage_dates, today)
    window_start = weekdays_before(today, CAP_WEEKDAYS)

    coverage_dates.any? { |date| date >= window_start && date < today }
  end
  private_class_method :added_recently?

  # Weekdays after the kind was last delivered, up to and including today. A
  # kind never delivered counts from the oldest exercise read, and a user
  # with no exercises has no gap at all.
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
