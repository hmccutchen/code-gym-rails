class SectionCount
  WINDOW       = 5
  STRETCH      = 1
  FLOOR        = 2
  MIN_SESSIONS = 3

  # Past two, skips mean absence rather than difficulty; a week away must not floor the next day.
  SKIP_RUN_CAP = 2

  def self.for(history)
    window = capped_window(history)
    return ceiling if window.size < MIN_SESSIONS

    mean = window.sum { |entry| credited_sections(entry) }.fdiv(window.size)

    (mean.round + STRETCH).clamp(FLOOR, ceiling)
  end

  # A drop credits an unanswered delivered section, up to the delivered count; an untouched day still earns zero.
  def self.credited_sections(entry)
    answered = entry.answered.to_i
    return 0 if answered.zero?

    [ answered + entry.dropped, entry.delivered_section_keys.size ].min
  end
  private_class_method :credited_sections

  def self.ceiling
    ExerciseSection::MAX_SECTIONS
  end
  private_class_method :ceiling

  # Skips past the cap are dropped, not zeroed, so an older real session backfills the window.
  def self.capped_window(history)
    run = 0

    history.filter_map { |entry|
      if entry.answered.nil?
        run += 1
        entry if run <= SKIP_RUN_CAP
      else
        run = 0
        entry
      end
    }.first(WINDOW)
  end
  private_class_method :capped_window
end
