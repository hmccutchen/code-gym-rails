class SectionCount
  WINDOW       = 5
  STRETCH      = 1
  FLOOR        = 2
  MIN_SESSIONS = 3

  def self.for(history)
    window = history.first(WINDOW)
    return ceiling if window.size < MIN_SESSIONS

    mean = window.sum { |entry| credited_sections(entry) }.fdiv(window.size)

    (mean.round + STRETCH).clamp(FLOOR, ceiling)
  end

  # A drop credits an unanswered delivered section, up to the delivered count.
  def self.credited_sections(entry)
    [ entry.answered + entry.dropped, entry.delivered_section_keys.size ].min
  end
  private_class_method :credited_sections

  def self.ceiling
    ExerciseSection::MAX_SECTIONS
  end
  private_class_method :ceiling
end
