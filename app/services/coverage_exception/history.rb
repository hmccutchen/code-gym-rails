# What CoverageException reads about past days. last_seen maps a kind key to
# the last date it was delivered; coverage_dates are the days a coverage
# addition was planned, whether or not its section survived the judge;
# first_date is the oldest exercise read, from which a kind never delivered
# counts as unseen.
class CoverageException
  History = Data.define(:last_seen, :coverage_dates, :first_date) do
    # One query, newest first, so the first date seen for a key is its last.
    def self.for(user)
      rows = user.daily_exercises.where(date: ...Date.current).order(date: :desc).limit(HISTORY_LIMIT)
                 .select(:id, :date, :problem_set, :plan_notes).to_a

      new(last_seen: rows.each_with_object({}) { |row, seen| row.active_section_keys.each { |key| seen[key] ||= row.date } },
          coverage_dates: rows.select { |row| row.plan_notes["coverage"].present? }.map(&:date),
          first_date: rows.last&.date)
    end
  end
end
