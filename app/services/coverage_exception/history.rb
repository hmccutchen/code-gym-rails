# What CoverageException reads about past days. last_seen maps a kind key to
# the last date it was delivered; coverage_dates are the days a coverage
# addition was planned, whether or not its section survived the judge;
# first_date is the oldest exercise read, from which a kind never delivered
# counts as unseen.
class CoverageException
  History = Data.define(:last_seen, :coverage_dates, :first_date) do
    # Read first, over the cap's window only: on a day the cap holds, the
    # gaps are never needed and their problem sets are never loaded.
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
