# Runs a drafted set through the judge, retries each rejection once with its
# kind and drafted concept fixed, and decides what ships.
#
# Each section is judged in its own thread, like grading. A rejection buys one
# regeneration of that section, unless the drafted concept normalized to
# "other", which is rejected directly rather than spending a retry on an
# unusable tag. A second rejection drops the section. A judge that fails or
# answers invalidly leaves the draft unedited: the judge is never why a day
# has no set. The finish step runs last so its logs describe the final set.
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
    outcomes = judge_all(set)

    resolve_rejections(set, outcomes).each do |key, section, outcome|
      outcomes[key] = outcome
      section ? set[key] = section : set.delete(key)
    end

    dropped = outcomes.select { |_, outcome| outcome[:dropped] }.keys
    finish(set, dropped, outcomes)
    AiService::JudgedSet.new(problem_set: set, dropped_sections: dropped, outcomes: outcomes)
  end

  private

  def finish(set, dropped, outcomes)
    dropped_concepts = dropped.to_h { |key| [ key, @draft.problem_set.dig(key, "concept") ] }
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
      thread_in_caller_zone { [ key, *resolve_rejection(kind, set[key], outcomes[key]) ] }
    }.map(&:value)
  end

  # [key, outcome, section].
  def judge_outcome(kind, section)
    verdict, latency = judge_with_fallback(kind, section)
    outcome = { status: :keep, issues: [], principle: nil, retries: 0,
                dropped: false, fallback: nil, latency_ms: latency }
    return [ kind.key, outcome.merge(fallback: verdict), section ] if verdict.is_a?(String)

    [ kind.key, outcome.merge(judgment(verdict)), apply_verdict(verdict, section) ]
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
  # what. Safe to log — the judge is never shown the answer key, so nothing
  # it quotes can be from one.
  def judgment(verdict)
    { status: verdict.status, issues: verdict.issues.map { |issue| issue[:type] }, principle: verdict.principle,
      evidence: verdict.evidence, reason: verdict.reason }
  end

  def rejected_keys(outcomes)
    outcomes.select { |_, outcome| outcome[:status] == :reject }.keys
  end

  # The one regeneration a rejection buys, judged again. Returns
  # [section_or_nil, outcome]; nil is a drop. `retries` counts a retry that was
  # actually judged, not merely attempted, so a retry whose generation failed
  # reads as 0. A judge that fails on the re-judge keeps the retry for the
  # same reason it keeps a draft.
  def resolve_rejection(kind, section, outcome)
    outcome = outcome.merge(retry_principle: nil)
    return drop_or_anchor(kind, section, outcome.merge(retries: 0)) if section["concept"] == "other"

    retried = retry_section(kind, section["concept"])
    return drop_or_anchor(kind, section, outcome.merge(retries: 0)) if retried.nil?

    verdict, latency = judge_with_fallback(kind, retried)
    outcome = outcome.merge(retries: 1, latency_ms: outcome[:latency_ms] + latency)
    return [ retried, outcome.merge(status: :keep, fallback: verdict) ] if verdict.is_a?(String)

    verdict_summary = judgment(verdict)
    if verdict.reject?
      return drop_or_anchor(kind, retried, outcome.merge(retry_principle: verdict_summary[:principle],
                                                         retry_issues: verdict_summary[:issues],
                                                         retry_evidence: verdict_summary[:evidence],
                                                         retry_reason: verdict_summary[:reason]))
    end

    # The draft's principle and issues survive a retry the judge accepted:
    # they are the only record this section was rejected at all, and
    # rejection rate per principle is read off these entries.
    [ apply_verdict(verdict, retried), outcome.merge(status: verdict_summary[:status], retry_issues: verdict_summary[:issues]) ]
  end

  # A second rejection drops the section — unless the kind is the one the day
  # cannot be delivered without, which ships the best section it has and says
  # so. The principle is recorded either way, so the rejection is still read
  # off the log.
  #
  # The delivered section is stamped too, because the outcomes are gone once
  # the day is written: without it nothing in the set says the app judged this
  # section broken and shipped it anyway. Nothing reads the stamp yet — it is
  # graded and feeds mastery exactly as any other section does — so it exists
  # to make such a day diagnosable and to give a later exclusion something to
  # read.
  def drop_or_anchor(kind, section, outcome)
    return [ nil, outcome.merge(dropped: true) ] if kind.droppable?

    [ section.merge("anchored" => true), outcome.merge(fallback: "anchor") ]
  end

  # Returns [verdict, ms], or [fallback reason, ms] when the judge could not
  # answer.
  def judge_with_fallback(kind, section)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    difficulty = @draft.difficulty
    verdict = @providers.call.judge_section.call(
      @user, kind, section,
      rung: difficulty.rung_for(kind, skill_level: @user.skill_level), locked: difficulty.locked?(kind)
    )
    [ verdict, elapsed_ms(started) ]
  rescue JudgeVerdict::Invalid, AiService::Error, *AiService::INFRASTRUCTURE_ERRORS => e
    reason = judge_fallback_reason(e)
    Rails.logger.warn("[judge_fallback] user=#{@user.id} section=#{kind.key} reason=#{reason}: #{e.message}")
    [ reason, elapsed_ms(started) ]
  end

  # A timeout is the judge's commonest failure and the one worth separating,
  # so it is named here rather than in AiService.error_code_for, which the
  # review path shares and where "other" is already what a timeout means.
  def judge_fallback_reason(error)
    case error
    when JudgeVerdict::Invalid     then "invalid_output"
    when AiService::TimeoutError   then "timeout"
    else                                AiService.error_code_for(error)
    end
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
