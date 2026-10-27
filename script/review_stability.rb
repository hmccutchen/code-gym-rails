# Prints ratings and counts only, never an answer, a key or review text, so its output can be pasted anywhere.
class ReviewStability
  RUNS = 5

  # Failures no later call can recover from, so the run stops at the first one.
  STOP_FAILURES = %w[bad_key out_of_credit daily_limit setup].freeze

  # The mean output per grade in the 2026-10-09 calibration run (docs/decisions/grading-rubric.md), thinking included.
  MEAN_OUTPUT_TOKENS = 900

  class Stop < StandardError; end

  Row = Data.define(:date, :section, :rung, :stored_rating, :stored_provider, :ratings, :failures) do
    def graded = ratings.select { |rating| ConceptMastery::AI_RATING_RANK.key?(rating) }
    def stored? = ConceptMastery::AI_RATING_RANK.key?(stored_rating)
    def comparable? = graded.size >= 2
    def changed? = graded.uniq.size > 1
    def spread = graded.map { |rating| ConceptMastery::AI_RATING_RANK.fetch(rating) }.minmax.then { |low, high| high - low }
    def jumped? = spread > 1
    def matching_stored = graded.count(stored_rating)
  end

  def self.spread_levels = (0...ConceptMastery::AI_RATING_RANK.size).to_a

  def self.usable_rating(review)
    rating = review.is_a?(Hash) ? review["rating"] : nil
    rating if ConceptMastery::AI_RATING_RANK.key?(rating)
  end

  def initialize(out:)
    @out = out
  end

  def print_plan(entries, runs:, route:, estimate:)
    @out.puts "=== review_stability plan: #{route[:model]} · #{runs} runs per section · no provider call made ==="
    @out.puts "sections: #{entries.size} · #{entries.group_by(&:section).sort.map { |kind, rows| "#{kind} #{rows.size}" }.join(', ')}"
    @out.puts "day's last recorded provider: #{entries.map { |entry| entry.review_provider.presence || 'unrecorded' }.tally.sort.map { |name, count| "#{name} #{count}" }.join(', ')}"
    @out.puts "calls: #{entries.size * runs}"
    @out.puts estimate
  end

  def print_report(rows, runs:, route:, regrade_provider:, cost_line:)
    @out.puts "=== review_stability: #{route[:model]} · #{runs} runs per section · #{cost_line} ==="
    rows.each { |row| @out.puts section_line(row) }
    @out.puts
    groups = rows.group_by(&:section).sort.to_h.merge("all kinds" => rows)
    groups.each { |label, group| @out.puts summary_line(label, group) }
    @out.puts
    @out.puts "drift, not stability: regrades on #{regrade_provider} matching the stored rating, which moves with every model and prompt change since the stored review"
    @out.puts "a day records the provider of its last review attempt, so a section graded in an earlier attempt may come from another"
    groups.each { |label, group| drift_lines(label, group, regrade_provider).each { |line| @out.puts line } }
  end

  private

  def section_line(row)
    "#{row.date} #{row.section} (#{row.rung}): stored #{row.stored_rating.presence || 'none'} · runs #{row.ratings.map { |rating| rating || '-' }.join(' ')}" \
      "#{" · failed #{row.failures}" if row.failures.positive?}"
  end

  def summary_line(label, rows)
    comparable = rows.select(&:comparable?)
    spreads    = comparable.map(&:spread).tally

    "#{label}: #{rows.size} sections · changed between runs #{share(comparable.count(&:changed?), comparable.size)} · " \
      "spread #{self.class.spread_levels.map { |level| "#{level}:#{spreads.fetch(level, 0)}" }.join(' ')} · " \
      "moved more than one level #{share(comparable.count(&:jumped?), comparable.size)} · " \
      "failed or unusable grades #{rows.sum(&:failures)}#{" · too few grades to compare #{rows.size - comparable.size}" if comparable.size < rows.size}"
  end

  # Rows with no stored rating stay out of the denominator, since there is nothing to drift from.
  def drift_lines(label, rows, regrade_provider)
    stored = rows.select(&:stored?)
    lines  = stored.group_by(&:stored_provider).sort_by { |provider, _| provider.to_s }.map do |provider, group|
      "#{label} drift, #{provider.present? ? "day's last recorded provider #{provider}" : 'no recorded provider'}: " \
        "matching #{share(group.sum(&:matching_stored), group.sum { |row| row.graded.size })}#{provider_note(provider, regrade_provider)}"
    end
    missing = rows.size - stored.size
    missing.positive? ? lines << "#{label} drift: #{missing} sections with no stored rating left out" : lines
  end

  def provider_note(provider, regrade_provider)
    return " · the stored review may come from a different provider than the regrade" if provider.blank?
    return "" if provider == regrade_provider

    " · not the regrade's provider (#{regrade_provider}), so this also compares providers"
  end

  # Counts only: with a dozen sections a kind, a percentage claims precision the sample doesn't have.
  def share(count, total) = "#{count}/#{total}"
end
