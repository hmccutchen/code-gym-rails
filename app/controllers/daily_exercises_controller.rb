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

  # POST /regenerate — manually re-run today's exercise generation, capped at
  # once per day via regenerated_at. Replaces the existing DailyExercise row's
  # contents in place; never creates a second row for the same day. The provider
  # call runs on the worker, so this action never blocks on it.
  def regenerate
    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: "No exercise set to regenerate yet." unless exercise

    unless claim_regeneration!(exercise)
      return redirect_to root_path, alert: "You've already generated a new set today."
    end

    current_user.update!(last_generation_error_date: nil, last_generation_error: nil)
    RegenerateExerciseJob.perform_later(user_id: current_user.id)
    redirect_to root_path, flash: { generating: true }
  end

  private

  # Atomic claim against a concurrent double-submit, mirroring
  # ResponsesController#claim_review!: a single UPDATE ... WHERE is serialized by
  # Postgres row locking, so only one caller can win. The same statement enforces
  # the once-per-day gate and lets an expired claim be retaken.
  def claim_regeneration!(exercise)
    DailyExercise.where(id: exercise.id, user_id: current_user.id, regenerated_at: nil)
                 .where("regenerating_since IS NULL OR regenerating_since < ?",
                        DailyExercise::REGENERATION_STALE_AFTER.ago)
                 .update_all(regenerating_since: Time.current) == 1
  end
end
