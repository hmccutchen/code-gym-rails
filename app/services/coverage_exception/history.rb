# coverage_dates count planned additions even when the judge dropped the section.
class CoverageException
  History = Data.define(:last_seen, :coverage_dates, :first_date) do
    # Read first and over the cap's window only, so a capped day never loads problem sets.
    def self.recent_coverage_dates(user, today: Date.current)
      user.daily_exercises.where(date: CoverageException.cap_window_start(today)...today)
          .where("plan_notes ? 'coverage'").pluck(:date)
    end

    # One query, newest first, so the first date seen for a key is its last.
    def self.for(user, coverage_dates:)
      rows = user.daily_exercises.where(date: ...Date.current).order(date: :desc).limit(HISTORY_LIMIT)
                 .select(:id, :date, :problem_set).to_a

      new(last_seen: rows.each_with_object({}) { |row, seen| row.active_section_keys.each { |key| seen[key] ||= row.date } },
          coverage_dates: coverage_dates, first_date: rows.last&.date)
    end
  end
end
