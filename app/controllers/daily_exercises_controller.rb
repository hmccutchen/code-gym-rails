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
  #
  # Regeneration destroys today's response (RegenerateExerciseJob), so it carries
  # the same reviewed-state guard as ResponsesController#start_over: once a
  # review exists, ConceptMastery.record_review! has already moved tier, streak
  # and retention state off it, and destroying the row would leave that state
  # standing with no evidence behind it. Guarded here rather than only in the
  # view, since the view's button is not what makes the destroy unsafe.
  def regenerate
    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: "No exercise set to regenerate yet." unless exercise

    # Named daily_response, not response: a local named `response` shadows the
    # controller's own response object for the rest of the action.
    daily_response = exercise.daily_response
    if daily_response&.reviewed?
      return redirect_to root_path, alert: "Today's set has already been reviewed — that review is already part of your concept tracking, so it can't be replaced. Tomorrow's set will build on it."
    end
    if daily_response&.reviewing?
      return redirect_to root_path, alert: "A review is being generated for today's set — try again in a moment."
    end

    unless claim_regeneration!(exercise)
      return redirect_to root_path, alert: "You've already generated a new set today."
    end

    current_user.update!(last_generation_error_date: nil, last_generation_error: nil)
    # The claim is already committed, so an enqueue failure would strand the
    # user behind a spinner no worker will ever clear — release it before
    # reporting, so a retry is possible immediately rather than in six minutes.
    begin
      RegenerateExerciseJob.perform_later(user_id: current_user.id)
    rescue StandardError => e
      Rails.logger.error("Failed to enqueue RegenerateExerciseJob for user #{current_user.id}: #{e.class}: #{e.message}")
      release_regeneration!(exercise)
      return redirect_to root_path, alert: "Couldn't start regeneration. Please try again."
    end

    redirect_to root_path, flash: { generating: true }
  end

  private

  # Atomic claim against a concurrent double-submit, mirroring
  # ResponsesController#claim_review!: a single UPDATE ... WHERE is serialized by
  # Postgres row locking, so only one caller can win. The same statement enforces
  # the once-per-day gate and lets an expired claim be retaken.
  def claim_regeneration!(exercise)
    current_user.daily_exercises
                .where(id: exercise.id, regenerated_at: nil)
                .where("regenerating_since IS NULL OR regenerating_since < ?",
                       DailyExercise::REGENERATION_STALE_AFTER.ago)
                .update_all(regenerating_since: Time.current) == 1
  end

  # Written through the relation rather than the loaded record: `exercise` was
  # read before claim_regeneration!'s update_all, so it still believes
  # regenerating_since is nil and assigning nil would dirty nothing.
  def release_regeneration!(exercise)
    current_user.daily_exercises.where(id: exercise.id).update_all(regenerating_since: nil)
  end
end
