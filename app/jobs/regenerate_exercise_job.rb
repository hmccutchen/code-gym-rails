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

    problem_set = AiService.for(user).generate_exercise(user, language: exercise.language)

    kept_review = false
    ActiveRecord::Base.transaction do
      # The reviewed-state guard in DailyExercisesController#regenerate runs a
      # worker hop and a 10-30s provider call earlier than this destroy, so a
      # review started in another tab can land inside that window. Re-asked here
      # under the row lock #review itself takes, which is what makes the answer
      # trustworthy rather than merely re-read: a review claimed but not yet
      # committed still holds the lock, so it is never destroyed half-written.
      # The whole regeneration is abandoned rather than the destroy alone —
      # replacing the problem_set under a review would leave that review
      # describing code the day no longer shows.
      existing = exercise.reload_daily_response
      existing&.lock!
      if existing&.reviewed? || existing&.reviewing?
        kept_review = true
        raise ActiveRecord::Rollback
      end

      existing&.destroy
      exercise.update!(
        problem_set:        problem_set,
        generated_at:       Time.current,
        regenerated_at:     Time.current,
        regenerating_since: nil
      )
    end

    return keep_reviewed_set(user, exercise) if kept_review

    user.update!(last_generation_error_date: nil, last_generation_error: nil) if user.last_generation_error_date.present?
    Rails.logger.info("Regenerated exercise for #{user.email} on #{Date.current}")
  rescue AiService::AuthenticationError => e
    release(user, exercise, "Your API key was rejected — check it in Settings.", e)
  rescue AiService::RateLimitError => e
    release(user, exercise, "The AI provider is rate-limiting requests — try again shortly.", e)
  rescue AiService::TimeoutError => e
    release(user, exercise, "Generation took longer than the provider's budget — try again.", e)
  rescue AiService::Error => e
    release(user, exercise, e.message, e)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    release(user, exercise, "Generation returned an unusable set — try again.", e)
  end

  # Same shape as a failed attempt — the claim is released and regenerated_at
  # stays nil, so the day's one regeneration is still available once the review
  # is no longer the reason to refuse. The generated set is discarded: it was
  # built for a day whose sections must not change.
  def keep_reviewed_set(user, exercise)
    Rails.logger.info("Kept the reviewed set for #{user.email} on #{Date.current}; discarded the regenerated one")
    exercise.update_columns(regenerating_since: nil)
    user.update!(last_generation_error_date: Date.current,
                 last_generation_error: "your review landed first, and replacing a reviewed set would discard it — today's reviewed set was kept.")
  end

  # regenerated_at is deliberately left untouched: a failed attempt must not
  # consume the user's one regeneration for the day.
  def release(user, exercise, message, error)
    Rails.logger.error("Failed to regenerate exercise for #{user.email}: #{error.message}")
    exercise&.update_columns(regenerating_since: nil)
    user.update!(last_generation_error_date: Date.current, last_generation_error: message)
  end
end
