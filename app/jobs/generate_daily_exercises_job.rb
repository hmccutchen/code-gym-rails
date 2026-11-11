class GenerateDailyExercisesJob < ApplicationJob
  queue_as :provider_calls

  limits_concurrency key: ->(args = {}) { args[:user_id] },
                     group: ->(args = {}) { self.class.name if args[:user_id] },
                     to: 1, on_conflict: :discard,
                     duration: CallProfiles::JUDGED_GENERATION_BUDGET.seconds

  def perform(user_id: nil, remind: false)
    if user_id.nil?
      enqueue_due_users
    elsif remind
      batch_users.where(id: user_id).find_each { |user| in_zone_of(user) { generate_due_set(user) } }
    else
      # No hour gate here; active skips a user anonymized after the job was enqueued.
      User.active.where(id: user_id).find_each { |user| in_zone_of(user) { generate_now(user) } }
    end
  end

  private

  def batch_users = User.active.where.not(api_keys: nil).where(paused_generation_at: nil)

  def in_zone_of(user, &block) = Time.use_zone(user.effective_time_zone, &block)

  def enqueue_due_users
    batch_users.find_each do |user|
      in_zone_of(user) { enqueue_or_nudge(user) }
    rescue StandardError => e
      Rails.logger.error("Generation batch skipped user #{user.id}: #{e.class}: #{e.message}")
    end
  end

  def due_now? = Date.current.on_weekday? && Time.current.hour >= 8

  def enqueue_or_nudge(user)
    return unless due_now?

    if (exercise = DailyExercise.find_by(user: user, date: Date.current))
      nudge_if_due(user, exercise)
    else
      # Solid Queue discards this, returning false, when the user already has a generation queued or running.
      self.class.perform_later(user_id: user.id, remind: true)
    end
  end

  def generate_due_set(user)
    return unless due_now?
    return if DailyExercise.exists?(user: user, date: Date.current)

    generate_for(user)
    remind(user)
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
    generate_for(user)
  end

  def generate_for(user)
    date     = Date.current
    language = user.language_for_today
    service  = AiService.for(user)
    context  = PracticeGeneration.capture(user, date: date)
    judged   = service.generate_judged_exercise(user, language: language, schedule_context: context)

    result = PracticeGeneration.commit_new(user, context: context, judged: judged, language: language, drafted_by: service)
    if result.status == :superseded
      persist_failure(user) { user.record_generation_message!("Settings or another set changed while this set was being prepared. Generate again when ready.") }
      return
    end
    user.clear_generation_failure! if user.last_generation_error_date.present?

    Rails.logger.info("Generated exercise for user #{user.id} on #{Date.current}")
  rescue ProviderError::AllSectionsRejectedError => e
    Rails.logger.error("Failed to generate exercise for user #{user.id}: #{e.message}")
    persist_failure(user) { user.record_generation_message!(e.message) }
  rescue ProviderError, SetupError => e
    Rails.logger.error("Failed to generate exercise for user #{user.id} (#{ProviderFailure.classify(e)}): #{e.message}")
    persist_failure(user) { user.record_generation_failure!(e) }
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
