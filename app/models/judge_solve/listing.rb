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
  NEVER_SAMPLED_SOURCES = %w[synthetic].freeze
  PLACEHOLDER_COLUMNS = %i[id source rung created_at].freeze

  attr_reader :source, :show, :call, :n

  def initialize(source: nil, show: nil, call: nil, n: nil)
    @source = SOURCE_FILTERS.key?(source) ? source : SOURCE_FILTERS.keys.first
    @show = SHOWS.include?(show) ? show : SHOWS.first
    @call = CALL_FILTERS.include?(call) ? call : nil
    @n = (Integer(n.to_s, 10, exception: false) || SAMPLE_SIZE).clamp(1, MAX_SAMPLE_SIZE)
  end

  def filters
    { source: source, show: show, call: call, n: (n if matched_sample?) }.compact
  end

  def matched_sample? = show == "matched_sample"

  def entries
    @entries ||= (matched_sample? ? sample : listed).includes(:daily_exercise).to_a
  end

  def waiting
    @waiting ||= if matched_sample? || call.present? && call != JudgeSolve::UNCALLED
      []
    else
      JudgeSolve.withheld.where(source: sources).select(*PLACEHOLDER_COLUMNS).order(created_at: :desc, id: :desc).to_a
    end
  end

  def original_for(solve)
    originals[original_key(solve)] if solve.edit_reverted?
  end

  def counterparts_for(solve)
    counterparts.fetch(version_key(solve), []).reject { |other| other.source == solve.source }
  end

  private

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
    JudgeSolve.readable.where(source: sources - NEVER_SAMPLED_SOURCES, matched: true, human_call: nil)
              .where.not(rung: JudgedGeneration::SOLVE_MISMATCH_TOLERATED_AT)
              .order(Arel.sql("random()")).limit(n)
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
