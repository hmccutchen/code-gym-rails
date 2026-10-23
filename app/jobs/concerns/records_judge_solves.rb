# Design notes: docs/code-notes/app/jobs/concerns/records_judge_solves.md
module RecordsJudgeSolves
  private

  def record_judge_solves(exercise, solves, drafted_by:)
    return if solves.empty?

    draft_model = drafted_by.model_for("generate_exercise")
    JudgeSolve.transaction(requires_new: true) { JudgeSolve.record!(exercise, solves, draft_model: draft_model) }
  rescue JudgeSolve::RecordError => e
    Rails.logger.warn("[judge_solves_record_failed] user=#{exercise.user_id} exercise=#{exercise.id} reason=#{e.message}")
  end
end
