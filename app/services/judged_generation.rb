# Judges a drafted set, retries rejections with kind and concept fixed; see CLAUDE.md, "Two-stage generation".
class JudgedGeneration
  # judge_section(user, kind, section, rung:, locked:), retry_section(user, language, draft, kind, concept); both raise.
  Provider = Data.define(:judge_section, :retry_section)

  # Stays false until a person has read the blind-solve report on real drafts; principal_engineer never rejects on a mismatch.
  REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL = false
  SOLVE_MISMATCH_TOLERATED_AT = "principal_engineer".freeze

  RETRY_FIELDS = %i[retry_principle retry_issues retry_evidence retry_reason].freeze

  # `finish` is called once as finish.(set, dropped_concepts:, judge:, unhosted:).
  def self.call(user:, language:, draft:, providers:, finish:)
    new(user, language, draft, providers, finish).call
  end

  def initialize(user, language, draft, providers, finish)
    @user      = user
    @language  = language
    @draft     = draft
    @providers = providers
    @finish    = finish
  end

  def call
    # Pruned on a deep copy: the draft keeps every section's concept for the finish step's logs and the unhosted list.
    set = ProblemSetIngest.prune_to_expected_keys(@draft.problem_set, expected_keys: @draft.kinds.map(&:key))
    outcomes = judge_all(set).merge(unusable_outcomes)

    resolve_rejections(set, outcomes).each do |key, section, outcome|
      outcomes[key] = outcome
      section ? set[key] = section : set.delete(key)
    end

    dropped = outcomes.select { |_, outcome| outcome[:dropped] }.keys
    reject_empty_day!(set, dropped)
    finish(set, dropped, outcomes)
    AiService::JudgedSet.new(problem_set: set, dropped_sections: dropped, outcomes: outcomes)
  end

  private

  # A planned section ingest refused counts as a rejection the judge never saw.
  def unusable_outcomes
    planned = @draft.kinds.map(&:key)
    Array(@draft.unusable_sections).select { |section| planned.include?(section.key) }.to_h do |section|
      [ section.key, { status: :reject, issues: [], principle: nil, retries: 0, dropped: false, fallback: nil,
                       latency_ms: 0, unusable: true } ]
    end
  end

  # Includes a section ingest left out of the set; nil when there is no concept to fix a retry to.
  def drafted_concept(key)
    @draft.problem_set.dig(key, "concept") ||
      Array(@draft.unusable_sections).find { |section| section.key == key }&.concept
  end

  def reject_empty_day!(set, dropped)
    return if ExerciseSection.resolved_keys(set).any?

    Rails.logger.warn("[judge_all_rejected] user=#{@user.id} dropped=#{dropped.join(',')}")
    raise AiService::AllSectionsRejectedError
  end

  def finish(set, dropped, outcomes)
    dropped_concepts = dropped.to_h { |key| [ key, drafted_concept(key) ] }
    @finish.call(set, dropped_concepts: dropped_concepts, judge: outcomes, unhosted: UnhostedConcepts.for(@draft.plan, dropped_concepts))
  end

  # No thread writes the set; each returns its section and this assembles the results.
  def judge_all(set)
    threads = @draft.kinds.filter_map do |kind|
      section = set[kind.key]
      thread_in_caller_zone { judge_outcome(kind, section) } if section
    end

    threads.map(&:value).each_with_object({}) do |(key, outcome, section), outcomes|
      set[key]      = section
      outcomes[key] = outcome
    end
  end

  # Returns [key, section_or_nil, outcome] per rejection.
  def resolve_rejections(set, outcomes)
    rejected_keys(outcomes).map { |key|
      kind = ExerciseSection.find(key)
      thread_in_caller_zone { [ key, *resolve_rejection(kind, drafted_concept(key), outcomes[key]) ] }
    }.map(&:value)
  end

  # [key, outcome, section].
  def judge_outcome(kind, section)
    verdict, latency = judge_with_fallback(kind, section)
    outcome = { status: :keep, issues: [], principle: nil, retries: 0,
                dropped: false, fallback: nil, latency_ms: latency }
    return [ kind.key, outcome.merge(fallback: verdict), section ] if verdict.is_a?(String)

    matched = solve_matched(kind, section, verdict)
    verdict = settled(kind, verdict, matched)
    shipped, outcome = confirmed_edit(kind, section, verdict, with_solve(outcome, matched).merge(judgment(kind, verdict)))
    [ kind.key, outcome, shipped ]
  end

  # The unedited draft ships when a re-judged edit is rejected, unanswered or solved against the key.
  def confirmed_edit(kind, section, verdict, outcome)
    edited = apply_verdict(verdict, section)
    return [ edited, outcome ] unless verdict.edit? && kind.rejudge_edits?

    check, latency = judge_with_fallback(kind, edited)
    matched  = check.is_a?(String) ? nil : solve_matched(kind, edited, check)
    outcome  = with_solve(outcome, matched).merge(latency_ms: outcome[:latency_ms] + latency)
    reverted = check.is_a?(String) || check.reject? || matched == false
    [ reverted ? section : edited, outcome.merge(edit_reverted: reverted) ]
  end

  # `source` marks a scenario ProblemSetIngest stamped from the real file, which the judge must not rewrite.
  def apply_verdict(verdict, section)
    edited = verdict.apply(section)
    return edited if section["source"].blank?

    edited.merge("scenario" => section["scenario"])
  end

  # A kind the judge solves blind keeps evidence and reason out: the judge's own words could be an answer candidate.
  def judgment(kind, verdict)
    summary = { status: verdict.status, issues: issue_types(verdict), principle: verdict.principle }
    return summary if kind.judge_solve_options

    summary.merge(evidence: verdict.evidence, reason: verdict.reason)
  end

  def issue_types(verdict) = verdict.issues.map { |issue| issue[:type] }

  def rejected_keys(outcomes)
    outcomes.select { |_, outcome| outcome[:status] == :reject }.keys
  end

  # Returns [section_or_nil, outcome]; nil is a drop. `retries` counts only retries that were actually judged.
  def resolve_rejection(kind, concept, outcome)
    retry_fields = kind.judge_solve_options ? RETRY_FIELDS - %i[retry_evidence retry_reason] : RETRY_FIELDS
    outcome = outcome.merge(retries: 0, **retry_fields.index_with { [] })
    return drop(outcome) if concept.nil? || concept == "other"

    kind.judge_retries.times do
      retried = retry_section(kind, concept)
      return drop(outcome) if retried.nil?

      section, outcome, settled = rejudge(kind, retried, outcome)
      return [ section, outcome ] if settled
    end
    drop(outcome)
  end

  # Returns [section, outcome, settled]; settled is false only when the judge rejected the retry.
  def rejudge(kind, retried, outcome)
    verdict, latency = judge_with_fallback(kind, retried)
    outcome = outcome.merge(retries: outcome[:retries] + 1, latency_ms: outcome[:latency_ms] + latency)
    return [ retried, record_attempt(outcome).merge(status: :keep, fallback: verdict), true ] if verdict.is_a?(String)

    matched = solve_matched(kind, retried, verdict)
    verdict = settled(kind, verdict, matched)
    outcome = record_attempt(with_solve(outcome, matched), verdict)
    return [ retried, outcome, false ] if verdict.reject?

    # Keep the draft's principle and issues: they are the only record that this section was ever rejected.
    shipped, outcome = confirmed_edit(kind, retried, verdict, outcome.merge(status: verdict.status))
    [ shipped, outcome, true ]
  end

  # A judge that could not answer appends an empty entry, so the retry lists stay aligned.
  def record_attempt(outcome, verdict = nil)
    attempt = { retry_principle: verdict&.principle, retry_issues: verdict ? issue_types(verdict) : [],
                retry_evidence: verdict&.evidence, retry_reason: verdict&.reason }
    outcome.merge(attempt.slice(*outcome.keys).to_h { |field, value| [ field, outcome[field] + [ value ] ] })
  end

  def drop(outcome)
    [ nil, outcome.merge(dropped: true) ]
  end

  # nil for a kind the judge does not solve; a mismatch log never carries the key or the judge's pick.
  def solve_matched(kind, section, verdict)
    return if verdict.solve.nil?

    kind.solve_matches_key?(section, verdict.solve).tap do |matched|
      Rails.logger.warn("[judge_solve_mismatch] user=#{@user.id} section=#{kind.key} rung=#{rung_for(kind)}") unless matched
    end
  end

  # One entry per judged version of the section, draft first.
  def with_solve(outcome, matched)
    matched.nil? ? outcome : outcome.merge(solve_matched: outcome.fetch(:solve_matched, []) + [ matched ])
  end

  # A mismatch that rejects becomes an underdetermined rejection: the stated facts led a careful reader to the other piece.
  def settled(kind, verdict, matched)
    return verdict unless REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL && matched == false && !verdict.reject?
    return verdict if rung_for(kind) == SOLVE_MISMATCH_TOLERATED_AT

    JudgeVerdict.new(status: :reject, principle: "underdetermined", solve: verdict.solve)
  end

  def rung_for(kind)
    @draft.difficulty.rung_for(kind, skill_level: @user.skill_level)
  end

  # Returns [verdict, ms], or [fallback reason, ms] when the judge could not answer.
  def judge_with_fallback(kind, section)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    verdict = @providers.call.judge_section.call(
      @user, kind, section, rung: rung_for(kind), locked: @draft.difficulty.locked?(kind)
    )
    [ verdict, elapsed_ms(started) ]
  rescue JudgeVerdict::Invalid, AiService::Error, *AiService::INFRASTRUCTURE_ERRORS => e
    reason = AiService.judge_fallback_reason(e)
    Rails.logger.warn("[judge_fallback] user=#{@user.id} section=#{kind.key} reason=#{reason}#{fallback_detail(kind, e)}")
    [ reason, elapsed_ms(started) ]
  end

  # For a blind-solve kind the refused value can be the solve, so only the reason code is logged.
  def fallback_detail(kind, error)
    kind.judge_solve_options ? "" : ": #{error.message}"
  end

  # Failure is a drop, never a raised set.
  def retry_section(kind, concept)
    @providers.call.retry_section.call(@user, @language, @draft, kind, concept)
  rescue AiService::Error, *AiService::INFRASTRUCTURE_ERRORS => e
    Rails.logger.warn("[judge_retry_failed] user=#{@user.id} section=#{kind.key}: #{e.message}")
    nil
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
  end

  # Time.zone is per thread; carry the caller's zone so every ApiUsage row of one fan-out lands on the same date.
  def thread_in_caller_zone(&work)
    zone = Time.zone
    Thread.new { Time.use_zone(zone, &work) }
  end
end
