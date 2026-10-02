# The completion rule: how many sections recent finishing allows today's set,
# one of DaySize's inputs. Pure: takes history, returns a number, touches no
# database.
class SectionCount
  WINDOW       = 5
  STRETCH      = 1
  FLOOR        = 2
  MIN_SESSIONS = 3

  # Past two, a run of skipped exercises stops being a difficulty signal and
  # becomes absence. A week away must not return someone to a floored day.
  SKIP_RUN_CAP = 2

  def self.for(history)
    window = capped_window(history)
    return ceiling if window.size < MIN_SESSIONS

    mean = window.sum { |entry| credited_sections(entry) }.fdiv(window.size)

    (mean.round + STRETCH).clamp(FLOOR, ceiling)
  end

  # A drop fills in for an unanswered delivered section, up to the delivered
  # count, so the judge removing a section does not shorten tomorrow. A day
  # with nothing answered earns nothing: a drop cannot turn an untouched day
  # into finished work.
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

  # Skips past the cap are dropped, not zeroed, so an older real session
  # backfills the window instead of the absence compounding.
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
