class DailyExercisesController < ApplicationController
  # POST /generate — manually trigger on-demand generation for today, for the
  # case where DashboardController#show's automatic weekday trigger didn't
  # fire (weekends). No-ops (just redirects) if today's exercise already
  # exists, so a duplicate click can't enqueue a second generation.
  def generate
    return redirect_to root_path if current_user.daily_exercises.for_date.exists?

    # Clear any stale failure from an earlier attempt today so /dashboard/status
    # doesn't report "failed" (with yesterday's message) while this retry is
    # still in flight — see GenerateDailyExercisesJob's status-polling comment.
    current_user.update!(last_generation_error_date: nil, last_generation_error: nil)
    GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
    redirect_to root_path, flash: { generating: true }
  end

  # POST /regenerate — manually re-run today's exercise generation, capped
  # at once per day via regenerated_at. Replaces the existing DailyExercise
  # row's contents in place; never creates a second row for the same day.
  def regenerate
    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: "No exercise set to regenerate yet." unless exercise

    if exercise.regenerated_at.present?
      return redirect_to root_path, alert: "You've already generated a new set today."
    end

    problem_set = AiService.for(current_user).generate_exercise(current_user, language: exercise.language, blocking: true)

    ActiveRecord::Base.transaction do
      exercise.daily_response&.destroy
      exercise.update!(
        problem_set:    problem_set,
        generated_at:   Time.current,
        regenerated_at: Time.current
      )
    end

    redirect_to root_path, notice: "New set generated!"
  rescue AiService::AuthenticationError
    redirect_to root_path, alert: "Your API key was rejected — check it in Settings."
  rescue AiService::RateLimitError => e
    redirect_to root_path, alert: "The AI provider is rate-limiting requests — try again shortly."
  rescue AiService::Error => e
    redirect_to root_path, alert: "Couldn't generate a new set: #{e.message}"
  end
end
