class DailyExercisesController < ApplicationController
  REGENERATION_BLOCKED = {
    reviewed:  "flash.daily_exercises.already_reviewed",
    reviewing: "flash.daily_exercises.review_in_progress"
  }.freeze

  GENERATE_PER_HOUR = 3

  rate_limit to: GENERATE_PER_HOUR, within: 1.hour, by: -> { current_user.id },
             with: -> { redirect_to root_path, alert: t("flash.daily_exercises.generate_limited") },
             store: LazyCacheStore.new, name: "generate", only: :generate, unless: :own_key?

  # POST /generate — for days the dashboard's weekday trigger skips; redirects without enqueuing if today's set exists.
  def generate
    if current_user.trial_ended?
      return redirect_to root_path, alert: trial_ended_text(:generation)
    end

    current_user.carry_held_set_forward!
    return redirect_to root_path if current_user.daily_exercises.for_date.exists?

    current_user.clear_generation_failure!
    GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
    redirect_to root_path, flash: { generating: true }
  end

  # POST /regenerate — once a day; refused once reviewed, since destroying the response would orphan mastery state.
  def regenerate
    return redirect_to root_path, alert: trial_ended_text(:regeneration) if current_user.trial_ended?

    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: t("flash.daily_exercises.nothing_to_regenerate") unless exercise

    blocker = exercise.daily_response&.replace_blocker
    return redirect_to root_path, alert: t(REGENERATION_BLOCKED.fetch(blocker)) if blocker

    claim = exercise.claim_regenerating!(regenerated_at: nil)
    return redirect_to root_path, alert: t("flash.daily_exercises.already_regenerated") unless claim

    current_user.clear_generation_failure!
    # The claim is committed, so release it on an enqueue failure or the user waits behind a spinner nobody clears.
    begin
      RegenerateExerciseJob.perform_later(user_id: current_user.id)
    rescue StandardError => e
      Rails.logger.error("Failed to enqueue RegenerateExerciseJob for user #{current_user.id}: #{e.class}: #{e.message}")
      exercise.release_regenerating!(claim)
      return redirect_to root_path, alert: t("flash.daily_exercises.regeneration_not_started")
    end

    redirect_to root_path, flash: { generating: true }
  end

  private

  def trial_ended_text(surface)
    ProviderFailureText.new("trial_ended", provider: current_user.provider, surface: surface, failed_at: Time.current,
                            zone: current_user.effective_time_zone).full
  end
end
