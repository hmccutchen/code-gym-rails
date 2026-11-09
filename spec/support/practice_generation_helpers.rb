module PracticeGenerationHelpers
  def with_practice_context(result, user:, language:, schedule_context:)
    notes = result.plan_notes.dup
    if schedule_context.fetch(:active)
      plan = DailyPlan.for(user, language: language, schedule_context: schedule_context)
      notes["practice_schedule"] = plan.notes.fetch("practice_schedule")
    end
    result.with(plan_notes: notes, schedule_context: schedule_context)
  end
end
