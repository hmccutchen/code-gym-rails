# Design notes: docs/code-notes/app/jobs/regenerate_exercise_job.md
class RegenerateExerciseJob < ApplicationJob
  queue_as :default

  def perform(user_id:)
    user = User.active.find_by(id: user_id)
    return unless user

    Time.use_zone(user.effective_time_zone) { regenerate(user) }
  end

  private

  def regenerate(user)
    exercise = user.daily_exercises.for_date.first
    return unless exercise&.regenerating_since

    # The claim's timestamp is this worker's token; a cleared and retaken claim is present but not ours.
    claim = exercise.regenerating_since
    generated = generate(user, exercise.language, GenerationDeadline.new(claim + DailyExercise::REGENERATION_DEADLINE))

    kept_for = exercise.with_response_locked do |existing|
      # Re-read the claim under the lock: carry_forward or a later click can take it during the provider call.
      next :superseded if exercise.regenerating_since != claim

      blocker = existing&.replace_blocker
      next blocker if blocker

      existing&.destroy
      exercise.update!(
        problem_set:        generated.problem_set,
        dropped_sections:   generated.dropped_sections,
        plan_notes:         generated.plan_notes,
        generated_at:       Time.current,
        regenerated_at:     Time.current,
        regenerating_since: nil
      )
      nil
    end

    return keep_superseded_set(user) if kept_for == :superseded
    return keep_reviewed_set(user, exercise, kept_for, claim) if kept_for

    user.clear_generation_failure! if user.last_generation_error_date.present?
    Rails.logger.info("Regenerated exercise for user #{user.id} on #{Date.current}")
  rescue AiService::AllSectionsRejectedError => e
    release(user, exercise, claim, e) { user.record_generation_message!(KEPT_SET_MESSAGES.fetch(:all_rejected)) }
  rescue AiService::Error => e
    release(user, exercise, claim, e) { user.record_generation_failure!(e) }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    release(user, exercise, claim, e) { user.record_generation_message!("Generation returned an unusable set — try again.") }
  end

  def generate(user, language, deadline)
    service = AiService.for(user)
    return service.generate_unjudged_exercise(user, language: language, deadline: deadline) unless AiService.judged_on?(Date.current)

    service.generate_judged_exercise(user, language: language, deadline: deadline)
  end

  KEPT_SET_MESSAGES = {
    all_rejected: "every section of the new set failed its quality check, so today's set was kept.",
    reviewed:     "your review landed first, and replacing a reviewed set would discard it — today's reviewed set was kept.",
    reviewing:    "a review was running for today's set, so it was kept rather than replaced mid-review."
  }.freeze

  def keep_superseded_set(user)
    Rails.logger.info("Regeneration claim for user #{user.id} on #{Date.current} was released or retaken under the call; discarded the regenerated one")
  end

  def keep_reviewed_set(user, exercise, kept_for, claim)
    Rails.logger.info("Kept today's set (#{kept_for}) for user #{user.id} on #{Date.current}; discarded the regenerated one")
    exercise.release_regenerating!(claim)
    user.record_generation_message!(KEPT_SET_MESSAGES.fetch(kept_for))
  end

  # regenerated_at stays untouched so a failed attempt doesn't use up the day's one regeneration.
  def release(user, exercise, claim, error)
    Rails.logger.error("Failed to regenerate exercise for user #{user.id}: #{error.message}")
    exercise&.release_regenerating!(claim)
    yield
  end
end
