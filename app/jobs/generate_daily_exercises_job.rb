class GenerateDailyExercisesJob < ApplicationJob
  queue_as :default

  limits_concurrency key: ->(args = {}) { args[:user_id] },
                     group: ->(args = {}) { self.class.name if args[:user_id] },
                     to: 1, on_conflict: :discard,
                     duration: AiService::JUDGED_GENERATION_BUDGET.seconds

  def perform(user_id: nil)
    if user_id
      # No hour gate here; active skips a user anonymized after the job was enqueued.
      User.active.where(id: user_id).find_each do |user|
        Time.use_zone(user.effective_time_zone) { generate_now(user) }
      end
    else
      User.active.where.not(api_keys: nil).where(paused_generation_at: nil).find_each do |user|
        Time.use_zone(user.effective_time_zone) { generate_if_due(user) }
      end
    end
  end

  private

  def generate_if_due(user)
    return unless Date.current.on_weekday?
    return unless Time.current.hour >= 8

    if (exercise = DailyExercise.find_by(user: user, date: Date.current))
      nudge_if_due(user, exercise)
    else
      generate_for(user, judge: true)
      remind(user)
    end
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

  # generate_for swallows failures, so whether a set exists is read from the row, not a return value.
  def remind(user)
    return unless DailyExercise.exists?(user: user, date: Date.current)

    SendPushReminderJob.perform_later(user_id: user.id)
  end

  def generate_now(user)
    return if DailyExercise.exists?(user: user, date: Date.current)
    generate_for(user, judge: Date.current.on_weekday?)
  end

  def generate_for(user, judge: false)
    language = user.language_for_today
    service  = AiService.for(user)
    judged   = judge ? service.generate_judged_exercise(user, language: language)
                     : service.generate_unjudged_exercise(user, language: language)

    DailyExercise.create!(
      user:             user,
      date:             Date.current,
      problem_set:      judged.problem_set,
      dropped_sections: judged.dropped_sections,
      plan_notes:       judged.plan_notes,
      generated_at:     Time.current,
      language:         language
    )

    user.clear_generation_failure! if user.last_generation_error_date.present?

    Rails.logger.info("Generated exercise for user #{user.id} on #{Date.current}")
  rescue AiService::AllSectionsRejectedError => e
    Rails.logger.error("Failed to generate exercise for user #{user.id}: #{e.message}")
    persist_failure(user) { user.record_generation_message!(e.message) }
  rescue AiService::Error => e
    Rails.logger.error("Failed to generate exercise for user #{user.id} (#{ProviderFailure.classify(e)}): #{e.message}")
    persist_failure(user) { user.record_generation_failure!(e) }
    # Don't re-raise — one failure shouldn't block other users in the batch
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("Skipped duplicate generation for user #{user.id} on #{Date.current} (already generated concurrently)")
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors[:date].present?
    Rails.logger.info("Skipped duplicate generation for user #{user.id} on #{Date.current} (already generated concurrently)")
  end

  # Two generations can race and the loser writes last, so with a set present, clear the error instead.
  def persist_failure(user)
    if DailyExercise.exists?(user: user, date: Date.current)
      user.clear_generation_failure! if user.last_generation_error_date.present?
      return
    end

    yield
  end
end
