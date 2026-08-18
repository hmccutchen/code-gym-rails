# How many sections today's set holds, from how many the engineer has recently
# finished. Pure: takes history, returns a number, touches no database.
class SectionCount
  WINDOW       = 5
  STRETCH      = 1
  FLOOR        = 2
  MIN_SESSIONS = 3

  # Past two, a run of skipped exercises stops being a difficulty signal and
  # becomes absence. A week away must not return someone to a floored day.
  SKIP_RUN_CAP = 2

  # An early return, not a default fed through the rule below: with no path
  # from the sizing logic to the result, the override stays correct if that
  # logic is later rewritten.
  def self.for(history, adaptive: true)
    return ceiling unless adaptive

    window = capped_window(history)
    return ceiling if window.size < MIN_SESSIONS

    mean = window.sum { |entry| entry.answered.to_i }.fdiv(window.size)

    (mean.round + STRETCH).clamp(FLOOR, ceiling)
  end

  def self.ceiling
    ExerciseSection.slot_count
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
