# Design notes: docs/code-notes/app/services/judged_generation.md
class JudgedGeneration
  # judge_section(user, kind, section, rung:, locked:), retry_section(draft, kind, concept); both raise. judge_identity is a value.
  Provider = Data.define(:judge_section, :retry_section, :judge_identity)

  REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL = false
  SOLVE_MISMATCH_TOLERATED_AT = "principal_engineer".freeze

  RETRY_FIELDS = %i[retry_principle retry_issues retry_evidence retry_reason].freeze

  REFUSAL_DETAIL_LIMIT = 300

  def self.call(user:, draft:, providers:, finish:)
    new(user, draft, providers, finish).call
  end

  def initialize(user, draft, providers, finish)
    @user      = user
    @draft     = draft
    @providers = providers
    @finish    = finish
    @chains    = draft.kinds.to_h do |kind|
      [ kind.key, SolveChain.new(kind, rung: rung_for(kind), locked: draft.difficulty.locked?(kind)) ]
    end
  end

  def call
    set = ProblemSetIngest.prune_to_expected_keys(@draft.problem_set, expected_keys: @draft.kinds.map(&:key))
    outcomes = judge_all(set).merge(unusable_outcomes)

    resolve_rejections(outcomes).each do |key, section, outcome|
      outcomes[key] = outcome
      section ? set[key] = section : set.delete(key)
    end

    dropped = outcomes.select { |_, outcome| outcome[:dropped] }.keys
    reject_empty_day!(set, dropped)
    finish(set, dropped, outcomes)
    AiService::JudgedSet.new(problem_set: set, dropped_sections: dropped, outcomes: outcomes, plan_notes: @draft.plan.notes,
                             solves: @chains.flat_map { |key, chain| chain.solves(dropped: dropped.include?(key)) })
  end

  private

  def unusable_outcomes
    planned = @draft.kinds.map(&:key)
    Array(@draft.unusable_sections).select { |section| planned.include?(section.key) }.to_h do |section|
      [ section.key, { status: :reject, issues: [], principle: nil, retries: 0, dropped: false, fallback: nil,
                       latency_ms: 0, unusable: true } ]
    end
  end

  def drafted_concept(key)
    @draft.problem_set.dig(key, "concept") ||
      Array(@draft.unusable_sections).find { |section| section.key == key }&.concept
  end

  def reject_empty_day!(set, dropped)
    return if ExerciseSection.resolved_keys(set, daily: @draft.plan.daily_kinds).any?

    Rails.logger.warn("[judge_all_rejected] user=#{@user.id} dropped=#{dropped.join(',')}")
    raise ProviderError::AllSectionsRejectedError
  end

  def finish(set, dropped, outcomes)
    dropped_concepts = dropped.to_h { |key| [ key, drafted_concept(key) ] }
    @finish.call(set, dropped_concepts: dropped_concepts, judge: outcomes, unhosted: UnhostedConcepts.for(@draft.plan, dropped_concepts))
  end

  def judge_all(set)
    threads = @draft.kinds.filter_map do |kind|
      section = set[kind.key]
      CallerZoneThread.start { judge_outcome(kind, section) } if section
    end

    threads.map(&:value).each_with_object({}) do |(key, outcome, section), outcomes|
      set[key]      = section
      outcomes[key] = outcome
    end
  end

  def resolve_rejections(outcomes)
    rejected_keys(outcomes).map { |key|
      kind = ExerciseSection.find(key)
      CallerZoneThread.start { [ key, *resolve_rejection(kind, drafted_concept(key), outcomes[key]) ] }
    }.map(&:value)
  end

  def judge_outcome(kind, section)
    verdict, latency, pass = judge_with_fallback(kind, section)
    outcome = { status: :keep, issues: [], principle: nil, retries: 0,
                dropped: false, fallback: nil, latency_ms: latency }
    matched = record_pass(kind, section, verdict, pass, attempt: 0)
    return unjudged_draft(kind, section, outcome.merge(fallback: verdict)) if verdict.is_a?(String)

    verdict = settled(kind, verdict, matched)
    chain(kind).settle(0) unless verdict.reject?
    shipped, outcome = confirmed_edit(kind, section, verdict, with_solve(outcome, matched).merge(judgment(kind, verdict)))
    [ kind.key, outcome, shipped ]
  end

  def unjudged_draft(kind, section, outcome)
    chain(kind).settle(0)
    [ kind.key, outcome, section ]
  end

  def confirmed_edit(kind, section, verdict, outcome)
    edited = apply_verdict(verdict, section)
    return [ edited, outcome ] unless verdict.edit? && kind.rejudge_edits?

    check, latency, pass = judge_with_fallback(kind, edited)
    matched = check.is_a?(String) ? nil : solve_matched(kind, edited, check)
    outcome = with_solve(outcome, matched).merge(latency_ms: outcome[:latency_ms] + latency)
    reason  = revert_reason(check, matched)
    chain(kind).record_edit_check(edited, check, matched, pass, revert_reason: reason)
    [ reason ? section : edited, outcome.merge(edit_reverted: !reason.nil?) ]
  end

  def revert_reason(check, matched)
    if check.is_a?(String) then "judge_failed"
    elsif check.reject?    then "judge_rejected"
    elsif matched == false then "solve_mismatch"
    end
  end

  # `source` marks a scenario ProblemSetIngest stamped from the real file, which the judge must not rewrite.
  def apply_verdict(verdict, section)
    edited = verdict.apply(section)
    return edited if section["source"].blank?

    edited.merge("scenario" => section["scenario"])
  end

  def judgment(kind, verdict)
    summary = { status: verdict.status, issues: issue_types(verdict), principle: verdict.principle }
    return summary if kind.judge_solve_options

    summary.merge(evidence: verdict.evidence, reason: verdict.reason)
  end

  def issue_types(verdict) = verdict.issues.map { |issue| issue[:type] }

  def rejected_keys(outcomes)
    outcomes.select { |_, outcome| outcome[:status] == :reject }.keys
  end

  def resolve_rejection(kind, concept, outcome)
    retry_fields = kind.judge_solve_options ? RETRY_FIELDS - %i[retry_evidence retry_reason] : RETRY_FIELDS
    outcome = outcome.merge(retries: 0, **retry_fields.index_with { [] })
    return drop(outcome) if concept.nil? || concept == "other"

    @draft.plan.judge_retries(kind).times do
      retried = retry_section(kind, concept)
      return drop(outcome) if retried.nil?

      section, outcome, settled = rejudge(kind, retried, outcome)
      return [ section, outcome ] if settled
    end
    drop(outcome)
  end

  def rejudge(kind, retried, outcome)
    verdict, latency, pass = judge_with_fallback(kind, retried)
    outcome = outcome.merge(retries: outcome[:retries] + 1, latency_ms: outcome[:latency_ms] + latency)
    matched = record_pass(kind, retried, verdict, pass, attempt: outcome[:retries])
    return unjudged_retry(kind, retried, record_attempt(outcome).merge(fallback: verdict)) if verdict.is_a?(String)

    verdict = settled(kind, verdict, matched)
    outcome = record_attempt(with_solve(outcome, matched), verdict)
    return [ retried, outcome, false ] if verdict.reject?

    chain(kind).settle(outcome[:retries])

    # Keep the draft's principle and issues: they are the only record that this section was ever rejected.
    shipped, outcome = confirmed_edit(kind, retried, verdict, outcome.merge(status: verdict.status))
    [ shipped, outcome, true ]
  end

  def unjudged_retry(kind, retried, outcome)
    return [ *drop(outcome), true ] if outcome[:fallback] == ProviderError::DeadlineError.judge_fallback_reason

    chain(kind).settle(outcome[:retries])
    [ retried, outcome.merge(status: :keep), true ]
  end

  def record_attempt(outcome, verdict = nil)
    attempt = { retry_principle: verdict&.principle, retry_issues: verdict ? issue_types(verdict) : [],
                retry_evidence: verdict&.evidence, retry_reason: verdict&.reason }
    outcome.merge(attempt.slice(*outcome.keys).to_h { |field, value| [ field, outcome[field] + [ value ] ] })
  end

  def drop(outcome)
    [ nil, outcome.merge(dropped: true) ]
  end

  def solve_matched(kind, section, verdict)
    return if verdict.solve.nil?

    kind.solve_matches_key?(section, verdict.solve).tap do |matched|
      Rails.logger.warn("[judge_solve_mismatch] user=#{@user.id} section=#{kind.key} rung=#{rung_for(kind)}") unless matched
    end
  end

  def record_pass(kind, section, verdict, pass, attempt:)
    matched = solve_matched(kind, section, verdict) unless verdict.is_a?(String)
    chain(kind).record(section, verdict, matched, pass, attempt: attempt)
    matched
  end

  def chain(kind) = @chains.fetch(kind.key)

  def with_solve(outcome, matched)
    matched.nil? ? outcome : outcome.merge(solve_matched: outcome.fetch(:solve_matched, []) + [ matched ])
  end

  def settled(kind, verdict, matched)
    return verdict unless REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL && matched == false && !verdict.reject?
    return verdict if rung_for(kind) == SOLVE_MISMATCH_TOLERATED_AT

    JudgeVerdict.new(status: :reject, principle: "underdetermined", solve: verdict.solve)
  end

  def rung_for(kind)
    @draft.difficulty.rung_for(kind, skill_level: @user.skill_level)
  end

  def judge_with_fallback(kind, section)
    started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    provider = @providers.call
    verdict  = provider.judge_section.call(@user, kind, section, rung: rung_for(kind), locked: @draft.difficulty.locked?(kind))
    [ verdict, elapsed_ms(started), provider.judge_identity ]
  rescue JudgeVerdict::Invalid, ProviderError, *AiService::INFRASTRUCTURE_ERRORS => e
    reason = AiService.judge_fallback_reason(e)
    Rails.logger.warn("[judge_fallback] user=#{@user.id} section=#{kind.key} reason=#{reason}#{fallback_detail(e)}")
    [ reason, elapsed_ms(started), (provider&.judge_identity || {}).merge(unsolved_detail: refusal_message(e)) ]
  end

  def fallback_detail(error)
    message = refusal_message(error)
    message ? ": #{message}" : ""
  end

  def refusal_message(error)
    error.message.truncate(REFUSAL_DETAIL_LIMIT) if error.is_a?(JudgeVerdict::Invalid)
  end

  def retry_section(kind, concept)
    @providers.call.retry_section.call(@draft, kind, concept)
  rescue ProviderError, *AiService::INFRASTRUCTURE_ERRORS => e
    Rails.logger.warn("[judge_retry_failed] user=#{@user.id} section=#{kind.key}: #{e.message}")
    nil
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
  end
end
