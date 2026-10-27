# Prints ratings and counts only, never an answer, a key or review text, so its output can be pasted anywhere.
class ReviewStability
  RUNS = 5

  # Failures no later call can recover from, so the run stops at the first one.
  STOP_FAILURES = %w[bad_key out_of_credit daily_limit setup].freeze

  # The mean output per grade in the 2026-10-09 calibration run (docs/decisions/grading-rubric.md), thinking included.
  MEAN_OUTPUT_TOKENS = 900

  class Stop < StandardError; end

  Row = Data.define(:date, :section, :rung, :stored_rating, :ratings, :failures) do
    def graded = ratings.select { |rating| ConceptMastery::AI_RATING_RANK.key?(rating) }
    def comparable? = graded.size >= 2
    def changed? = graded.uniq.size > 1
    def spread = graded.map { |rating| ConceptMastery::AI_RATING_RANK.fetch(rating) }.minmax.then { |low, high| high - low }
    def jumped? = spread > 1
    def matching_stored = graded.count(stored_rating)
  end

  def self.spread_levels = (0...ConceptMastery::AI_RATING_RANK.size).to_a

  def initialize(out:)
    @out = out
  end

  def print_plan(entries, runs:, route:, estimate:)
    @out.puts "=== review_stability plan: #{route[:model]} · #{runs} runs per section · no provider call made ==="
    @out.puts "sections: #{entries.size} · #{entries.group_by(&:section).sort.map { |kind, rows| "#{kind} #{rows.size}" }.join(', ')}"
    @out.puts "reviewed by: #{entries.map { |entry| entry.review_provider.presence || 'unrecorded' }.tally.sort.map { |name, count| "#{name} #{count}" }.join(', ')}"
    @out.puts "calls: #{entries.size * runs}"
    @out.puts estimate
  end

  def print_report(rows, runs:, route:, cost_line:)
    @out.puts "=== review_stability: #{route[:model]} · #{runs} runs per section · #{cost_line} ==="
    rows.each { |row| @out.puts section_line(row) }
    @out.puts
    rows.group_by(&:section).sort.each { |kind, kind_rows| @out.puts summary_line(kind, kind_rows) }
    @out.puts summary_line("all kinds", rows)
  end

  private

  def section_line(row)
    "#{row.date} #{row.section} (#{row.rung}): stored #{row.stored_rating} · runs #{row.ratings.map { |rating| rating || '-' }.join(' ')}" \
      "#{" · failed #{row.failures}" if row.failures.positive?}"
  end

  def summary_line(label, rows)
    comparable = rows.select(&:comparable?)
    spreads    = comparable.map(&:spread).tally
    graded     = rows.sum { |row| row.graded.size }

    "#{label}: #{rows.size} sections · changed between runs #{share(comparable.count(&:changed?), comparable.size)} · " \
      "spread #{self.class.spread_levels.map { |level| "#{level}:#{spreads.fetch(level, 0)}" }.join(' ')} · " \
      "moved more than one level #{share(comparable.count(&:jumped?), comparable.size)} · " \
      "regrades matching the stored rating #{share(rows.sum(&:matching_stored), graded)} · " \
      "failed calls #{rows.sum(&:failures)}#{" · too few grades to compare #{rows.size - comparable.size}" if comparable.size < rows.size}"
  end

  # Counts only: with a dozen sections a kind, a percentage claims precision the sample doesn't have.
  def share(count, total) = "#{count}/#{total}"
end
