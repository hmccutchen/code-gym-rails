# Runs a drafted set through the judge, retries each rejection with its kind
# and drafted concept fixed, and decides what ships.
#
# Each section is judged in its own thread, like grading. A rejection buys up
# to the kind's judge_retries regenerations of that section, unless the
# drafted concept normalized to "other", which is rejected directly rather
# than spending a retry on an unusable tag. A planned section ingest refused
# as unusable counts as rejected before judging. Rejecting the last retry drops the
# section, whichever kind it is; a day with every section dropped is a failed
# generation (AiService::AllSectionsRejectedError), never an empty set. A judge
# that fails or answers invalidly leaves the draft unedited: the judge alone
# never costs a day its set. The finish step runs last so its logs describe the final set.
#
# The retries fan out the way the judging does, so a day with three of them
# waits for the slowest rather than their sum — serially they ran a full
# generation and a re-judge each, which put the worst case far past the single
# call this path replaced, on a schedule that ticks hourly.
#
# The provider is reached only through Provider, built fresh by `providers`
# for every call, so each thread has its own instance and therefore its own
# connection, and nothing mutable crosses a thread boundary.
class JudgedGeneration
  # judge_section: (user, kind, section, rung:, locked:) -> JudgeVerdict, raising
  #   JudgeVerdict::Invalid or an AiService error when the judge cannot answer.
  # retry_section: (user, language, draft, kind, concept) -> the regenerated
  #   section, raising when the regeneration fails.
  Provider = Data.define(:judge_section, :retry_section)

  # When true, a blind solve that disagrees with the answer key rejects the
  # section as underdetermined at the junior and senior rungs. Off until the
  # comparison script's blind-solve report on real drafts has been read and
  # approved; until then a mismatch is only logged. A principal_engineer
  # section never rejects on a mismatch, since both of its pieces are meant
  # to be defensible.
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
    # Pruned on a deep copy: the draft keeps the concept of every section,
    # including the ones dropped below, which the finish step's logs and the
    # unhosted list are named after.
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

  # A planned section ingest refused is treated as a rejection the judge
  # never saw: it gets the kind's retries with its drafted concept, then drops.
  def unusable_outcomes
    planned = @draft.kinds.map(&:key)
    Array(@draft.unusable_sections).select { |section| planned.include?(section.key) }.to_h do |section|
      [ section.key, { status: :reject, issues: [], principle: nil, retries: 0, dropped: false, fallback: nil,
                       latency_ms: 0, unusable: true } ]
    end
  end

  # The concept a drafted section carried, including one ingest left out of
  # the set; nil when there is none to fix a retry to.
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
    @finish.call(set, dropped_concepts: dropped_concepts, judge: outcomes, unhosted: unhosted_concepts(dropped_concepts))
  end

  # No thread writes the set: each returns its own section back and this
  # assembles both hashes, so the only shared state is read-only for the
  # length of the fan-out.
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
    [ kind.key, with_solve(outcome, matched).merge(judgment(kind, verdict)), apply_verdict(verdict, section) ]
  end

  # `source` marks a section ProblemSetIngest#ground_code_review! stamped its
  # own scenario onto — the real file, and that the copy is altered — so that
  # field is the server's to write, not an editable prose field.
  def apply_verdict(verdict, section)
    edited = verdict.apply(section)
    return edited if section["source"].blank?

    edited.merge("scenario" => section["scenario"])
  end

  # The quoted text and the stated reason travel with the principle: a count
  # per principle says how often the judge rejects, and only these say on
  # what. Safe to log for a kind the judge does not solve, because the judge
  # is never shown the answer key. A kind it solves blind keeps both out:
  # the solve makes the judge's own words an answer candidate.
  def judgment(kind, verdict)
    summary = { status: verdict.status, issues: issue_types(verdict), principle: verdict.principle }
    return summary if kind.judge_solve_options

    summary.merge(evidence: verdict.evidence, reason: verdict.reason)
  end

  def issue_types(verdict)
    verdict.issues.map { |issue| issue[:type] }
  end

  def rejected_keys(outcomes)
    outcomes.select { |_, outcome| outcome[:status] == :reject }.keys
  end

  # The regenerations a rejection buys, each judged again. Returns
  # [section_or_nil, outcome]; nil is a drop. `retries` counts retries that
  # were actually judged, not merely attempted, so a retry whose generation
  # failed is not counted. A judge that fails on a re-judge keeps that retry
  # for the same reason it keeps a draft. Each retry field is a list with one
  # entry per judged retry, in order; a blind-solve kind carries no evidence
  # or reason lists, for the reason #judgment gives.
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

  # Returns [section, outcome, settled]; settled is false only when the judge
  # rejected the retry.
  def rejudge(kind, retried, outcome)
    verdict, latency = judge_with_fallback(kind, retried)
    outcome = outcome.merge(retries: outcome[:retries] + 1, latency_ms: outcome[:latency_ms] + latency)
    return [ retried, record_attempt(outcome).merge(status: :keep, fallback: verdict), true ] if verdict.is_a?(String)

    matched = solve_matched(kind, retried, verdict)
    verdict = settled(kind, verdict, matched)
    outcome = record_attempt(with_solve(outcome, matched), verdict)
    return [ retried, outcome, false ] if verdict.reject?

    # The draft's principle and issues survive a retry the judge accepted:
    # they are the only record this section was rejected at all, and
    # rejection rate per principle is read off these entries.
    [ apply_verdict(verdict, retried), outcome.merge(status: verdict.status), true ]
  end

  # Appends one judged retry to each retry list the outcome carries; a judge
  # that could not answer appends an empty entry, so the lists stay aligned.
  def record_attempt(outcome, verdict = nil)
    attempt = { retry_principle: verdict&.principle, retry_issues: verdict ? issue_types(verdict) : [],
                retry_evidence: verdict&.evidence, retry_reason: verdict&.reason }
    outcome.merge(attempt.slice(*outcome.keys).to_h { |field, value| [ field, outcome[field] + [ value ] ] })
  end

  # A rejected last retry drops the section, whichever kind it is. The
  # principle is recorded either way, so the rejection is still read off the
  # log.
  def drop(outcome)
    [ nil, outcome.merge(dropped: true) ]
  end

  # Whether a blind solve agrees with the section's answer key, or nil for a
  # kind the judge does not solve. A mismatch is logged with the rung and
  # nothing else: never the key, never the judge's pick.
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

  # The verdict to act on: the judge's own, or, when a mismatch rejects, an
  # underdetermined rejection in its place, since the stated facts led a
  # careful reader to the other piece.
  def settled(kind, verdict, matched)
    return verdict unless REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL && matched == false && !verdict.reject?
    return verdict if rung_for(kind) == SOLVE_MISMATCH_TOLERATED_AT

    JudgeVerdict.new(status: :reject, principle: "underdetermined", solve: verdict.solve)
  end

  def rung_for(kind)
    @draft.difficulty.rung_for(kind, skill_level: @user.skill_level)
  end

  # Returns [verdict, ms], or [fallback reason, ms] when the judge could not
  # answer.
  def judge_with_fallback(kind, section)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    verdict = @providers.call.judge_section.call(
      @user, kind, section, rung: rung_for(kind), locked: @draft.difficulty.locked?(kind)
    )
    [ verdict, elapsed_ms(started) ]
  rescue JudgeVerdict::Invalid, AiService::Error, *AiService::INFRASTRUCTURE_ERRORS => e
    reason = AiService.judge_fallback_reason(e)
    Rails.logger.warn("[judge_fallback] user=#{@user.id} section=#{kind.key} reason=#{reason}: #{e.message}")
    [ reason, elapsed_ms(started) ]
  end

  # Failure is a drop, never a raised set.
  def retry_section(kind, concept)
    @providers.call.retry_section.call(@user, @language, @draft, kind, concept)
  rescue AiService::Error, *AiService::INFRASTRUCTURE_ERRORS => e
    Rails.logger.warn("[judge_retry_failed] user=#{@user.id} section=#{kind.key}: #{e.message}")
    nil
  end

  # What the plan asked for that no delivered section carries. The plan
  # attributes a concept to a section only in the fourth slot, so this is
  # decided after the fact the way AiService#log_retention decides honored:
  # the dropped section's own concept, matched against what the plan offered.
  def unhosted_concepts(dropped_concepts)
    plan          = @draft.plan
    retention     = (plan.due_checks + plan.fourth_due_checks).map(&:concept)
    reinforcement = (plan.reinforcement.to_a + plan.fourth_reinforcement.to_a).map { |entry| entry[:concept] }

    dropped_concepts.filter_map do |key, concept|
      planned_as = "retention" if retention.include?(concept)
      planned_as ||= "reinforcement" if reinforcement.include?(concept)
      { section: key, concept: concept, planned_as: planned_as } if planned_as
    end
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
  end

  # Time.zone is per thread, so a bare Thread.new runs in the default zone and
  # its ApiUsage row lands on a different date from the rows its caller writes
  # whenever the two zones straddle midnight. Carrying the caller's zone, rather
  # than rereading the user's, keeps every row of one fan-out on the date the
  # caller's own unthreaded calls use.
  def thread_in_caller_zone(&work)
    zone = Time.zone
    Thread.new { Time.use_zone(zone, &work) }
  end
end
