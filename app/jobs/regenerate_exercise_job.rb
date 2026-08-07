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

    ActiveRecord::Base.transaction do
      exercise.daily_response&.destroy
      exercise.update!(
        problem_set:        problem_set,
        generated_at:       Time.current,
        regenerated_at:     Time.current,
        regenerating_since: nil
      )
    end

    user.update!(last_generation_error_date: nil, last_generation_error: nil) if user.last_generation_error_date.present?
    Rails.logger.info("Regenerated exercise for #{user.email} on #{Date.current}")
  rescue AiService::AuthenticationError => e
    release(user, exercise, "Your API key was rejected — check it in Settings.", e)
  rescue AiService::RateLimitError => e
    release(user, exercise, "The AI provider is rate-limiting requests — try again shortly.", e)
  rescue AiService::Error => e
    release(user, exercise, e.message, e)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    release(user, exercise, "Generation returned an unusable set — try again.", e)
  end

  # regenerated_at is deliberately left untouched: a failed attempt must not
  # consume the user's one regeneration for the day.
  def release(user, exercise, message, error)
    Rails.logger.error("Failed to regenerate exercise for #{user.email}: #{error.message}")
    exercise&.update_columns(regenerating_since: nil)
    user.update!(last_generation_error_date: Date.current, last_generation_error: message)
  end
end
