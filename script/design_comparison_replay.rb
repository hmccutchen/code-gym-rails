require_relative "forced_concept_drafts"

# Prints counts and ids only, never a solve, a key or section text, so its output can be pasted anywhere.
class DesignComparisonReplay
  KIND = ExerciseSection::DesignComparison
  SOURCE = "replay".freeze
  PIECE_FIELDS = KIND::PIECES.map { |piece| "piece_#{piece}" }.freeze
  JUDGE_FAILURES = [ JudgeVerdict::Invalid, ProviderError, SetupError, *AiService::INFRASTRUCTURE_ERRORS ].freeze

  # Worst case per call from docs/answer-key-trust-spec-2026-10-22.md, "Count and cost" and "Topping up".
  JUDGE_CALL_COST_BOUND = 0.019
  SYNTHETIC_SECTION_COST_BOUND = 0.12

  class MissingKey < StandardError; end

  def initialize(api_key:, out: $stdout, rejudge: false)
    @api_key = api_key.presence
    @out     = out
    @rejudge = rejudge
    @usage   = []
  end

  def dry_run
    pending = pending_exercises
    @out.puts "design comparisons to judge: #{pending.size} (already replayed and skipped: #{candidates.size - pending.size})"
    return if pending.empty?

    print_counts("week of", pending.group_by { |exercise| exercise.date.beginning_of_week })
    print_counts("user", pending.group_by(&:user_id))
    @out.puts "first date: #{pending.map(&:date).min}, last date: #{pending.map(&:date).max}"
    @out.puts "cost bound: at most $#{format('%.2f', pending.size * JUDGE_CALL_COST_BOUND)} " \
              "(#{pending.size} judge calls at $#{JUDGE_CALL_COST_BOUND} each)"
  end

  def run
    service = claude_service
    pending = pending_exercises
    rows = pending.each_with_index.map do |exercise, index|
      replay(service, exercise).tap { |row| print_progress(index + 1, pending.size, "daily_exercise #{exercise.id}", row) }
    end
    print_summary(rows)
  end

  def synthesize(user_id, count)
    service = claude_service
    user    = User.find(user_id)
    plan    = synthetic_plan(user.language_for_today, count)
    @out.puts "synthesizing #{count} design comparisons, cost bound $#{format('%.2f', count * SYNTHETIC_SECTION_COST_BOUND)}"
    rows = plan.each_with_index.filter_map do |(rung, concept), index|
      row = synthetic(service, user, rung, concept)
      print_progress(index + 1, count, "#{rung} #{concept}", row)
      row
    end
    print_summary(rows)
  end

  def candidates
    section = "problem_set -> #{quote(KIND.key)}"
    scope = DailyExercise.where("#{section} -> #{quote(KIND::ANSWER_KEY_FIELD)} ->> 'better' IN (:pieces)", pieces: KIND::PIECES)
                         .where("#{section} ->> 'pitched_at' IN (:rungs)", rungs: KindDifficulty::LEVELS)
                         .where.not("dropped_sections ? :key", key: KIND.key)
    PIECE_FIELDS.reduce(scope) { |found, field| found.where("coalesce(#{section} ->> #{quote(field)}, '') <> ''") }
                .order(:date, :id)
  end

  def pending_exercises
    exercises = candidates.includes(:user).to_a
    return exercises if @rejudge

    done = JudgeSolve.where(source: SOURCE, section: KIND.key, daily_exercise_id: exercises.map(&:id))
                     .pluck(:daily_exercise_id, :section_digest).to_set
    exercises.reject { |exercise| done.include?([ exercise.id, SectionDigest.call(exercise.problem_set[KIND.key]) ]) }
  end

  private

  def replay(service, exercise)
    section = exercise.problem_set[KIND.key]
    solve   = judged_solve(service, exercise.user, section, rung: section["pitched_at"])
    JudgeSolve.record!(exercise, [ solve ], source: SOURCE)
    solve
  end

  def synthetic(service, user, rung, concept)
    section = service.send(:retry_section, ForcedConceptDrafts.rung_draft(user, user.language_for_today, rung), KIND, concept)
    return unless section

    solve = judged_solve(service, user, section, rung: rung).with(shipped: false)
    JudgeSolve.record_synthetic!([ solve ], draft_model: service.model_for("retry_section"))
    solve
  rescue ProviderError, SetupError => e
    @out.puts "draft failed: #{rung} #{concept} (#{AiService.judge_fallback_reason(e)})"
    nil
  end

  def judged_solve(service, user, section, rung:)
    identity = { judge_provider: service.class.provider_key, judge_model: service.model_for("judge_section") }
    verdict, pass = judge(service, user, section, rung, identity)
    matched = KIND.solve_matches_key?(section, verdict.solve) unless verdict.is_a?(String) || verdict.solve.nil?
    chain = JudgedGeneration::SolveChain.new(KIND, rung: rung, locked: false)
    chain.record(section, verdict, matched, pass, attempt: 0)
    chain.settle(0)
    chain.solves(dropped: false).first
  end

  def judge(service, user, section, rung, identity)
    [ service.judge_section(user, KIND, section, rung: rung, locked: false), identity ]
  rescue *JUDGE_FAILURES => e
    [ AiService.judge_fallback_reason(e), identity.merge(unsolved_detail: refusal_detail(e)) ]
  end

  def refusal_detail(error)
    error.message.truncate(JudgedGeneration::REFUSAL_DETAIL_LIMIT) if error.is_a?(JudgeVerdict::Invalid)
  end

  def synthetic_plan(language, count)
    rungs = KindDifficulty::LEVELS
    Array.new(count) do |index|
      rung     = rungs[index % rungs.size]
      concepts = ConceptVocabulary.selectable_for_section(KIND.key, language, rung: rung)
      [ rung, concepts[(index / rungs.size) % concepts.size] ]
    end
  end

  def print_counts(label, groups)
    groups.sort_by { |value, _| value }.each { |value, exercises| @out.puts "  #{label} #{value}: #{exercises.size}" }
  end

  def print_progress(position, total, label, solve)
    @out.puts "[#{position}/#{total}] #{label}: #{progress_status(solve)}"
  end

  def progress_status(solve)
    return "no section drafted, nothing recorded" if solve.nil?

    solve.unsolved_reason ? "unsolved (#{solve.unsolved_reason})" : "recorded"
  end

  def print_summary(solves)
    unsolved = solves.count(&:unsolved_reason)
    @out.puts "recorded #{solves.size} (#{solves.size - unsolved} solved, #{unsolved} unsolved) · " \
              "#{@usage.sum { |call| call[:tokens_in] }} in / #{@usage.sum { |call| call[:tokens_out] }} out tokens"
    @out.puts "Read the agreement on the admin page, which hides each record until its day is reviewed."
  end

  def quote(value) = DailyExercise.connection.quote(value)

  def claude_service
    raise MissingKey, "ANTHROPIC_API_KEY is not set. Calls are billed to it, never to a user's stored key." unless @api_key

    usage = @usage
    Class.new(ClaudeService) do
      def self.judges_review_prose? = false

      define_method(:log_usage) do |_user, result, purpose:|
        usage << { tokens_in: result[:input_tokens].to_i, tokens_out: result[:output_tokens].to_i }
      end
      define_method(:record_suggested_concept) { |_suggestion| }
      private :log_usage, :record_suggested_concept
    end.new(@api_key)
  end
end
