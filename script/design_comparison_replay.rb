require_relative "model_comparison"

# Prints counts and ids only, never a solve, a key or section text, so its output can be pasted anywhere.
class DesignComparisonReplay
  KIND = ExerciseSection::DesignComparison
  SOURCE = "replay".freeze
  SYNTHETIC = "synthetic".freeze
  PIECE_FIELDS = KIND::PIECES.map { |piece| "piece_#{piece}" }.freeze
  CALL_FAILURES = [ JudgeVerdict::Invalid, ProviderError, SetupError, *AiService::INFRASTRUCTURE_ERRORS ].freeze

  # The reply's own faults; any other failure is the account, the network or the provider, and stops the run.
  OWN_FAILURES = %w[invalid_output refusal truncated invalid_json].freeze

  # Estimates from docs/answer-key-trust-spec-2026-10-22.md, "Count and cost"; see this file's code note for the draft's.
  JUDGE_INPUT_TOKENS = 3_500
  DRAFT_INPUT_TOKENS = 10_000

  class MissingKey < StandardError; end
  class Stop < StandardError; end

  def self.worst_case_cost(purpose, input_tokens)
    model  = ClaudeService::MODEL_FOR_PURPOSE.fetch(purpose, ClaudeService::DEFAULT_ROUTE)[:model]
    price  = ClaudeService::PRICE_PER_MILLION.fetch(model)
    output = output_cap(purpose)
    { model: model, input: input_tokens, output: output,
      dollars: (input_tokens * price.input + output * price.output) / 1_000_000.0 }
  end

  def self.output_cap(purpose) = CallProfiles.fetch(purpose)[:max_tokens] || ClaudeService::MAX_TOKENS

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

    print_counts("week of", pending.group_by { |exercise| exercise.date.beginning_of_week }.sort)
    print_counts("user", pending.group_by(&:user_id).sort)
    @out.puts "first date: #{pending.map(&:date).min}, last date: #{pending.map(&:date).max}"
    print_bound(pending.size, "judge call", [ judge_cost ])
  end

  def run
    service = claude_service
    pending = pending_exercises
    rows = until_stopped(pending, label: ->(exercise) { "daily_exercise #{exercise.id}" }) do |exercise|
      replay(service, exercise)
    end
    print_summary(rows)
  end

  def synthesize(user_id, target, run: false)
    user = User.find(user_id)
    Time.use_zone(user.effective_time_zone) do
      plan = synthetic_plan(user.language_for_today, target)
      print_synthetic_plan(plan, target)
      next unless run && plan.any?

      service = claude_service
      rows = until_stopped(plan, label: ->(slot) { slot.join(" ") }) { |rung, concept| synthetic(service, user, rung, concept) }
      print_summary(rows)
    end
  end

  def candidates
    scope = DailyExercise.where("problem_set -> :kind -> :key_field ->> 'better' IN (:pieces)",
                                kind: KIND.key, key_field: KIND::ANSWER_KEY_FIELD, pieces: KIND::PIECES)
                         .where("problem_set -> :kind ->> 'pitched_at' IN (:rungs)", kind: KIND.key, rungs: KindDifficulty::LEVELS)
                         .where.not("dropped_sections ? :kind", kind: KIND.key)
    PIECE_FIELDS.reduce(scope) do |found, field|
      found.where("coalesce(problem_set -> :kind ->> :field, '') <> ''", kind: KIND.key, field: field)
    end.order(:date, :id)
  end

  def pending_exercises
    exercises = candidates.includes(:user).to_a
    return exercises if @rejudge

    done = JudgeSolve.where(source: SOURCE, section: KIND.key, daily_exercise_id: exercises.map(&:id))
                     .pluck(:daily_exercise_id, :section_digest).to_set
    exercises.reject { |exercise| done.include?([ exercise.id, SectionDigest.call(exercise.problem_set[KIND.key]) ]) }
  end

  private

  def until_stopped(items, label:)
    rows    = []
    current = nil
    items.each_with_index do |item, index|
      current = item
      row = yield(item)
      print_progress(index + 1, items.size, label.call(item), row)
      rows << row if row
    end
    rows
  rescue Stop => e
    @out.puts "stopped at #{label.call(current)}: #{e.message}. Nothing was recorded for it; " \
              "#{rows.size} of #{items.size} recorded before it. Run again to continue."
    rows
  end

  def replay(service, exercise)
    section = exercise.problem_set[KIND.key]
    solve   = judged_solve(service, exercise.user, section, rung: section["pitched_at"])
    JudgeSolve.record!(exercise, [ solve ], source: SOURCE)
    solve
  rescue JudgeSolve::RecordError => e
    raise Stop, e.message
  end

  def synthetic(service, user, rung, concept)
    section = draft(service, user, rung, concept)
    return unless section

    solve = judged_solve(service, user, section, rung: rung).with(shipped: false)
    JudgeSolve.record_synthetic!([ solve ], draft_model: service.model_for("retry_section"))
    solve
  rescue JudgeSolve::RecordError => e
    raise Stop, e.message
  end

  def draft(service, user, rung, concept)
    service.send(:retry_section, ForcedConceptDrafts.rung_draft(user, user.language_for_today, rung), KIND, concept)
  rescue *CALL_FAILURES => e
    @out.puts "draft failed: #{rung} #{concept} (#{own_failure_reason(e)})"
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
  rescue *CALL_FAILURES => e
    [ own_failure_reason(e), identity.merge(unsolved_detail: refusal_detail(e)) ]
  end

  def own_failure_reason(error)
    reason = AiService.judge_fallback_reason(error)
    raise Stop, "provider call failed (#{reason})" unless OWN_FAILURES.include?(reason)

    reason
  end

  def refusal_detail(error)
    error.message.truncate(JudgedGeneration::REFUSAL_DETAIL_LIMIT) if error.is_a?(JudgeVerdict::Invalid)
  end

  def synthetic_plan(language, target)
    rungs = KindDifficulty::LEVELS
    (JudgeSolve.where(source: SYNTHETIC, section: KIND.key).count...target).map do |index|
      rung     = rungs[index % rungs.size]
      concepts = ConceptVocabulary.selectable_for_section(KIND.key, language, rung: rung)
      [ rung, concepts[(index / rungs.size) % concepts.size] ]
    end
  end

  def judge_cost = self.class.worst_case_cost("judge_section", JUDGE_INPUT_TOKENS)

  def print_synthetic_plan(plan, target)
    @out.puts "synthetic design comparisons to draft: #{plan.size} (target #{target}, already recorded: #{target - plan.size})"
    print_counts("rung", plan.group_by(&:first).sort_by { |rung, _| KindDifficulty::LEVELS.index(rung) })
    print_bound(plan.size, "section", [ self.class.worst_case_cost("retry_section", DRAFT_INPUT_TOKENS), judge_cost ])
  end

  def print_bound(count, unit, calls)
    per_unit = calls.sum { |call| call[:dollars] }
    @out.puts "worst-case bound: $#{format('%.2f', count * per_unit)} (#{count} × $#{format('%.3f', per_unit)} per #{unit}; " \
              "#{calls.map { |call| cost_assumption(call) }.join(', then ')})"
  end

  def cost_assumption(call)
    "#{call[:model]} at list price with #{call[:input]} input tokens estimated and its full #{call[:output]}-token output cap"
  end

  def print_counts(label, groups)
    groups.each { |value, items| @out.puts "  #{label} #{value}: #{items.size}" }
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
