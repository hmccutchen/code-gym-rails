require "csv"

# Rows are the audit's undefined terms; only the visible ones count toward coverage.
class GlossaryCoverageReport
  TOP = 20

  def self.parse(text)
    CSV.parse(text, col_sep: "\t", headers: true, quote_char: "\x00").map(&:to_h)
  end

  def self.read(paths)
    paths.flat_map { |path| parse(File.read(path)) }
  end

  def initialize(rows, terms: Glossary::TERMS, pattern: Glossary::TERM_PATTERN, resolver: Glossary.method(:key_for))
    @rows = rows.select { |row| row["visible"] == "yes" }
    @terms = terms
    @pattern = pattern
    @resolver = resolver
  end

  def summary
    counts = @rows.map { |row| classify(row["term"]) }.tally
    by_form = @rows.count { |row| by_form?(row["term"]) }
    { visible: @rows.size, whole_term: counts.fetch(:whole_term, 0), by_form: by_form,
      inside_term: counts.fetch(:inside_term, 0), unmatched: counts.fetch(:unmatched, 0) }
  end

  def top_unmatched(limit)
    pairs = unmatched_rows.group_by { |row| row["term"] }.transform_values { |rows| rows.map { |row| row.values_at("concept", "language") }.uniq.size }
    pairs.sort_by { |term, count| [ -count, term ] }.first(limit)
  end

  def print(out = $stdout)
    summary.each { |name, count| out.puts "#{name}: #{count}" }
    out.puts "Top #{TOP} unmatched terms (distinct concept/language pairs):"
    top_unmatched(TOP).each { |term, count| out.puts format("%4d  %s", count, term) }
  end

  private

  def unmatched_rows
    @rows.select { |row| classify(row["term"]) == :unmatched }
  end

  def classify(term)
    return :whole_term if @terms.key?(term.downcase) || by_form?(term)
    return :inside_term if term.match?(@pattern)

    :unmatched
  end

  def by_form?(term)
    !@terms.key?(term.downcase) && @resolver&.call(term).present?
  end
end
