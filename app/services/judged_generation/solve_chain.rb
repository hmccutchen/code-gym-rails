# Design notes: docs/code-notes/app/services/judged_generation/solve_chain.md
class JudgedGeneration::SolveChain
  AlreadySettled = Class.new(StandardError)

  def initialize(kind, rung:, locked:)
    @kind     = kind
    @rung     = rung
    @locked   = locked
    @entries  = []
    @settled  = nil
  end

  def record(section, verdict, matched, pass, attempt:)
    return unless @kind.judge_solve_options

    @entries << [ build(section, verdict, matched, pass, attempt: attempt, edit_check: false), true ]
  end

  def record_edit_check(edited, check, matched, pass, revert_reason:)
    return unless @kind.judge_solve_options

    kept  = revert_reason.nil?
    solve = build(edited, check, matched, pass, attempt: @entries.last.first.attempt, edit_check: true)
    @entries.last[1] = false if kept
    @entries << [ solve.with(edit_reverted: !kept, revert_reason: revert_reason), kept ]
  end

  def settle(attempt)
    raise AlreadySettled, "#{@kind.key} settled at #{@settled}, then at #{attempt}" unless @settled.nil?

    @settled = attempt
  end

  def solves(dropped:)
    @entries.map { |solve, candidate| solve.with(**visibility(solve.attempt, candidate, dropped)) }
  end

  private

  def visibility(attempt, candidate, dropped)
    return { shipped: false, never_shown_reason: "section_dropped" } if dropped
    return { shipped: false, never_shown_reason: "replaced_by_retry" } if @settled && attempt < @settled

    { shipped: attempt == @settled && candidate, never_shown_reason: nil }
  end

  def build(section, verdict, matched, pass, attempt:, edit_check:)
    unsolved = verdict if verdict.is_a?(String)
    judged   = verdict unless unsolved
    JudgedGeneration::Solve.new(
      section: @kind.key, attempt: attempt, edit_check: edit_check, rung: @rung, locked: @locked,
      concept: section["concept"], judged_section: section.deep_dup,
      judge_status: judged&.status&.to_s, judge_pick: judged&.solve, key_better: @kind.keyed_solve(section),
      matched: matched, unsolved_reason: unsolved, unsolved_detail: pass[:unsolved_detail],
      edit_reverted: false, revert_reason: nil, judge_provider: pass[:judge_provider], judge_model: pass[:judge_model],
      shipped: nil, never_shown_reason: nil
    )
  end
end
