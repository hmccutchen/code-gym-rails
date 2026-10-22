# Design notes: docs/code-notes/app/models/judge_solve/counts.md
class JudgeSolve::Counts
  OUTCOMES = { "solved" => [ true, false ], "matched" => [ true ], "mismatched" => [ false ], "unsolved" => [ nil ] }.freeze
  MISMATCH_CALL_ROWS = ([ JudgeSolve::UNCALLED ] + JudgeSolve::MISMATCH_CALLS).freeze
  MATCHED_CALL_ROWS = ([ JudgeSolve::UNCALLED ] + JudgeSolve::MATCHED_CALLS).freeze

  def outcome(source, name)
    OUTCOMES.fetch(name).sum { |matched| outcomes.fetch([ source, matched ], 0) }
  end

  def reverted(source, reason)
    reverts.fetch([ source, reason ], 0)
  end

  def withheld
    @withheld ||= JudgeSolve.withheld_section_count
  end

  def mismatch_call(source, call)
    mismatch_calls.fetch([ source, stored_call(call) ], 0)
  end

  def matched_call(source, call)
    matched_calls.fetch([ source, stored_call(call) ], 0)
  end

  private

  def outcomes
    @outcomes ||= JudgeSolve.readable.group(:source, :matched).count
  end

  def reverts
    @reverts ||= JudgeSolve.readable.where(edit_reverted: true).group(:source, :revert_reason).count
  end

  def mismatch_calls
    @mismatch_calls ||= calls(matched: false)
  end

  def matched_calls
    @matched_calls ||= calls(matched: true)
  end

  def stored_call(call) = call == JudgeSolve::UNCALLED ? nil : call

  def calls(matched:)
    JudgeSolve.unscoped.from(latest_call_per_version(matched), :judge_solves).group(:source, :human_call).count
  end

  def latest_call_per_version(matched)
    JudgeSolve.readable.where(matched: matched)
              .where.not(rung: JudgedGeneration::SOLVE_MISMATCH_TOLERATED_AT)
              .select("DISTINCT ON (judge_solves.section_digest) judge_solves.source, judge_solves.human_call")
              .order(Arel.sql("judge_solves.section_digest, judge_solves.human_call IS NULL, judge_solves.human_called_at DESC NULLS LAST, judge_solves.id DESC"))
  end
end
