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
    generated = AiService.for(user).generate_unjudged_exercise(user, language: exercise.language)

    kept_for = nil
    ActiveRecord::Base.transaction do
      # Re-read the claim under the lock: carry_forward or a later click can take it during the provider call.
      exercise.lock!
      if exercise.regenerating_since != claim
        kept_for = :superseded
        raise ActiveRecord::Rollback # before touching the response: nothing here depends on it
      end
      # Not #lock!, which raises if #start_over deleted the row; #reviewing? also counts, as #review holds no lock mid-call.
      existing = DailyResponse.lock.find_by(daily_exercise_id: exercise.id)
      kept_for = :reviewed if existing&.reviewed?
      kept_for = :reviewing if kept_for.nil? && existing&.reviewing?
      raise ActiveRecord::Rollback if kept_for

      existing&.destroy
      exercise.update!(
        problem_set:        generated.problem_set,
        dropped_sections:   generated.dropped_sections,
        plan_notes:         generated.plan_notes,
        generated_at:       Time.current,
        regenerated_at:     Time.current,
        regenerating_since: nil
      )
    end

    return keep_superseded_set(user) if kept_for == :superseded
    return keep_reviewed_set(user, exercise, kept_for, claim) if kept_for

    user.clear_generation_failure! if user.last_generation_error_date.present?
    Rails.logger.info("Regenerated exercise for user #{user.id} on #{Date.current}")
  rescue AiService::Error => e
    release(user, exercise, claim, e) { user.record_generation_failure!(e) }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    release(user, exercise, claim, e) { user.record_generation_message!("Generation returned an unusable set — try again.") }
  end

  # A running review can still fail, so it gets its own message rather than claiming a review landed.
  KEPT_SET_MESSAGES = {
    reviewed:  "your review landed first, and replacing a reviewed set would discard it — today's reviewed set was kept.",
    reviewing: "a review was running for today's set, so it was kept rather than replaced mid-review."
  }.freeze

  # No error banner or release: the dashboard's set is intact and the claim is no longer ours.
  def keep_superseded_set(user)
    Rails.logger.info("Regeneration claim for user #{user.id} on #{Date.current} was released or retaken under the call; discarded the regenerated one")
  end

  # Releases the claim and leaves regenerated_at nil, so the day's one regeneration stays available.
  def keep_reviewed_set(user, exercise, kept_for, claim)
    Rails.logger.info("Kept today's set (#{kept_for}) for user #{user.id} on #{Date.current}; discarded the regenerated one")
    release_own_claim(exercise, claim)
    user.record_generation_message!(KEPT_SET_MESSAGES.fetch(kept_for))
  end

  # Where-guarded so a newer claim made after ours was cleared is left for its own worker.
  def release_own_claim(exercise, claim)
    DailyExercise.where(id: exercise.id, regenerating_since: claim).update_all(regenerating_since: nil)
  end

  # regenerated_at stays untouched so a failed attempt doesn't use up the day's one regeneration.
  def release(user, exercise, claim, error)
    Rails.logger.error("Failed to regenerate exercise for user #{user.id}: #{error.message}")
    release_own_claim(exercise, claim) if exercise
    yield
  end
end
