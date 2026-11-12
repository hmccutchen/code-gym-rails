class EnqueueDueGenerationsJob < ApplicationJob
  queue_as :default

  def perform
    fills_ran = !SchemaWait.migrations_pending?
    Rails.logger.warn("Generation hand-out skipped the unopened-set pause check: a migration is pending") unless fills_ran
    ScheduledGeneration.users.find_each do |user|
      Time.use_zone(user.effective_time_zone) { enqueue_or_nudge(user, check_unopened: fills_ran) }
    rescue StandardError => e
      Rails.logger.error("Generation batch skipped user #{user.id}: #{e.class}: #{e.message}")
    end
  end

  private

  def enqueue_or_nudge(user, check_unopened:)
    return unless ScheduledGeneration.due?(user)

    if (exercise = DailyExercise.find_by(user: user, date: Date.current))
      nudge_if_due(user, exercise)
    elsif check_unopened && UnopenedSets.pause?(user.daily_exercises.latest_openings, today: Date.current)
      pause_for_unopened_sets(user)
    else
      GenerateDailyExercisesJob.set(priority: JobPriority::SCHEDULED).perform_later(user_id: user.id, scheduled: true)
    end
  end

  def pause_for_unopened_sets(user)
    return unless user.pause_for_unopened_sets! == :paused

    Rails.logger.info("Paused generation for user #{user.id}: the last #{UnopenedSets::PAUSE_AFTER} sets went unopened")
  end

  def nudge_if_due(user, exercise)
    return unless PushNudgePlan.possible?(level: user.reminder_level, hour: Time.current.hour)

    response = user.daily_responses.find_by(daily_exercise: exercise)

    return unless PushNudgePlan.due?(
      level:            user.reminder_level,
      hour:             Time.current.hour,
      submitted:        response&.submitted?,
      last_activity_at: response&.updated_at
    )

    SendPushReminderJob.perform_later(user_id: user.id, kind: :nudge)
  end
end
