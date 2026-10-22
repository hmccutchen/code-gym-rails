# Design notes: docs/code-notes/app/models/judge_solve/listing.md
class JudgeSolve::Listing
  SOURCE_FILTERS = {
    "live" => %w[live], "real" => %w[live replay], "replay" => %w[replay],
    "synthetic" => %w[synthetic], "all" => JudgeSolve::SOURCES
  }.freeze
  SHOWS = %w[mismatches reverts matched_sample all].freeze
  CALL_FILTERS = ([ JudgeSolve::UNCALLED ] + JudgeSolve::MISMATCH_CALLS + JudgeSolve::MATCHED_CALLS).uniq.freeze
  SAMPLE_SIZE = 15
  MAX_SAMPLE_SIZE = 50
  PAGE_SIZE = 25
  WAITING_LIMIT = 30
  NEVER_SAMPLED_SOURCES = %w[synthetic].freeze
  PLACEHOLDER_VALUES = [
    :source, Arel.sql("(ARRAY_AGG(judge_solves.rung ORDER BY judge_solves.created_at, judge_solves.id))[1]"),
    Arel.sql("MIN(judge_solves.created_at)")
  ].freeze

  Placeholder = Data.define(:source, :rung, :created_at)

  attr_reader :source, :show, :call, :n

  def initialize(source: nil, show: nil, call: nil, n: nil, page: nil)
    @source = SOURCE_FILTERS.key?(source) ? source : SOURCE_FILTERS.keys.first
    @show = SHOWS.include?(show) ? show : SHOWS.first
    @call = CALL_FILTERS.include?(call) ? call : nil
    @n = (Integer(n.to_s, 10, exception: false) || SAMPLE_SIZE).clamp(1, MAX_SAMPLE_SIZE)
    @requested_page = positive_integer(page) || 1
  end

  def filters(page: self.page)
    { source: source, show: show, call: call, n: (n if matched_sample?), page: (page if page > 1) }.compact
  end

  def matched_sample? = show == "matched_sample"

  def page = @page ||= @requested_page.clamp(1, page_count)

  def page_count
    @page_count ||= matched_sample? ? 1 : [ (listed.count.to_f / PAGE_SIZE).ceil, 1 ].max
  end

  def entries
    @entries ||= (matched_sample? ? sample : listed.offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE)).to_a
  end

  def language_for(solve) = languages[solve.daily_exercise_id]

  def waiting
    @waiting ||= waiting? ? waiting_sections.limit(WAITING_LIMIT).pluck(*PLACEHOLDER_VALUES).map { |row| Placeholder.new(*row) } : []
  end

  def waiting_beyond_limit
    waiting? ? JudgeSolve.unscoped.from(waiting_sections.select("1"), :sections).count - waiting.size : 0
  end

  def original_for(solve)
    originals[original_key(solve)] if solve.edit_reverted?
  end

  def counterparts_for(solve)
    counterparts.fetch(version_key(solve), []).reject { |other| other.source == solve.source }
  end

  private

  def positive_integer(value) = Integer(value.to_s, 10, exception: false)&.then { |number| number if number.positive? }

  def sources = SOURCE_FILTERS.fetch(source)

  def listed
    scope = JudgeSolve.readable.where(source: sources)
    scope = scope.where(shown_condition) if shown_condition
    scope = scope.where(human_call: call == JudgeSolve::UNCALLED ? nil : call) if call
    scope.order(edit_reverted: :desc).order(Arel.sql("judge_solves.matched IS FALSE DESC")).order(created_at: :desc, id: :desc)
  end

  def shown_condition
    table = JudgeSolve.arel_table
    case show
    when "mismatches" then table[:matched].eq(false).or(table[:edit_reverted].eq(true))
    when "reverts" then table[:edit_reverted].eq(true)
    end
  end

  def sample
    return JudgeSolve.none if call && call != JudgeSolve::UNCALLED

    JudgeSolve.readable.where(source: sources - NEVER_SAMPLED_SOURCES, matched: true, human_call: nil)
              .where.not(rung: JudgedGeneration::SOLVE_MISMATCH_TOLERATED_AT)
              .order(Arel.sql("random()")).limit(n)
  end

  def waiting? = !matched_sample? && (call.nil? || call == JudgeSolve::UNCALLED)

  def waiting_sections
    JudgeSolve.withheld.where(source: sources).group(*JudgeSolve::WITHHELD_SECTION, :source)
              .order(Arel.sql("MIN(judge_solves.created_at) DESC"))
  end

  def languages
    @languages ||= DailyExercise.where(id: entries.filter_map(&:daily_exercise_id)).pluck(:id, :language).to_h
  end

  def originals
    @originals ||= begin
      reverted = entries.select(&:edit_reverted?)
      JudgeSolve.readable.where(edit_check: false, daily_exercise_id: reverted.map(&:daily_exercise_id))
                .index_by { |solve| original_key(solve) }
    end
  end

  def counterparts
    @counterparts ||= JudgeSolve.readable.where(daily_exercise_id: entries.filter_map(&:daily_exercise_id))
                                .select(:id, :source, :daily_exercise_id, :section, :section_digest)
                                .group_by { |solve| version_key(solve) }
  end

  def original_key(solve) = [ solve.daily_exercise_id, solve.section, solve.set_generated_at, solve.attempt ]

  def version_key(solve) = [ solve.daily_exercise_id, solve.section, solve.section_digest ]
end
