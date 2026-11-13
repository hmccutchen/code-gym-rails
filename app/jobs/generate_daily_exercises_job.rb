class GenerateDailyExercisesJob < ApplicationJob
  queue_as :provider_calls

  # Keeps one request from being queued twice; a click and a scheduled job never share a key.
  limits_concurrency key: ->(args = {}) { "#{args[:scheduled] ? 'scheduled' : 'click'}/#{args[:user_id]}" if args[:user_id] },
                     group: ->(args = {}) { self.class.name if args[:user_id] },
                     to: 1, on_conflict: :discard,
                     duration: CallProfiles::JUDGED_GENERATION_BUDGET.seconds

  SUPERSEDED_MESSAGE = "Settings or another set changed while this set was being prepared. Generate again when ready.".freeze

  def perform(user_id: nil, scheduled: false)
    # The release before EnqueueDueGenerationsJob ran the hourly hand-out as this class with no arguments.
    return EnqueueDueGenerationsJob.perform_later if user_id.nil?

    # Only a scheduled job re-checks pause and the hour; a click generates either way.
    candidates = scheduled ? ScheduledGeneration.users : User.active
    candidates.where(id: user_id).find_each do |user|
      Time.use_zone(user.effective_time_zone) { unless_account_deleted(user) { generate_under_claim(user, scheduled: scheduled) } }
    end
  end

  private

  def generate_under_claim(user, scheduled:)
    return if scheduled && !ScheduledGeneration.due?(user)

    claim = user.claim_generating!
    return Rails.logger.info("Skipped generation for user #{user.id}: another generation holds the claim") unless claim

    begin
      generate_missing_set(user, claim, remind: scheduled)
    ensure
      user.release_generating!(claim)
    end
  end

  def generate_missing_set(user, claim, remind:)
    return if set_today?(user)

    generate_for(user, claim)
    SendPushReminderJob.perform_later(user_id: user.id) if remind && set_today?(user)
  end

  def set_today?(user) = DailyExercise.exists?(user: user, date: Date.current)

  def generate_for(user, claim)
    key_used = user.key_in_use
    date     = Date.current
    language = user.language_for_today
    service  = AiService.for(user)
    context  = PracticeGeneration.capture(user, date: date)
    judged   = service.generate_judged_exercise(user, language: language, schedule_context: context)

    result = PracticeGeneration.commit_new(user, context: context, judged: judged, language: language, drafted_by: service)
    if result.status == :superseded
      persist_failure(user, claim) { user.record_generation_message!(SUPERSEDED_MESSAGE) }
      return
    end
    user.record_generation_success!
    queue_write_ups(user, result.exercise) if result.status == :saved

    Rails.logger.info(result.status == :duplicate ? skipped_duplicate(user) : "Generated exercise for user #{user.id} on #{Date.current}")
  rescue ProviderError::AllSectionsRejectedError => e
    Rails.logger.error("Failed to generate exercise for user #{user.id}: #{e.message}")
    persist_failure(user, claim) { report_failure(user, key_used) { user.record_generation_message!(e.message, provider: user.provider) } }
  rescue ProviderError, SetupError => e
    Rails.logger.error("Failed to generate exercise for user #{user.id} (#{ProviderFailure.classify(e)}): #{e.message}")
    persist_failure(user, claim) { report_failure(user, key_used) { user.record_generation_failure!(e) } }
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info(skipped_duplicate(user))
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors[:date].present?
    Rails.logger.info(skipped_duplicate(user))
  end

  # A page may be polling for this set, so a call whose key changed still ends in a failure the poll can report.
  def report_failure(user, key_used, &)
    user.report_call_failure(key_used, when_key_changed: -> { user.record_generation_message!(SUPERSEDED_MESSAGE) }, &)
  end

  def queue_write_ups(user, exercise)
    GenerateConceptReferenceJob.queue_missing(user, exercise.concept_pairs(before_submission: true), priority: JobPriority::BULK)
  end

  def skipped_duplicate(user) = "Skipped duplicate generation for user #{user.id} on #{Date.current} (already generated concurrently)"

  # A claim that went stale may be another job's by now, and that job writes the outcome.
  def persist_failure(user, claim)
    user.with_lock do
      next unless user.generating_since == claim
      next yield unless set_today?(user)

      user.clear_generation_failure! if user.last_generation_error_date.present?
    end
  end
end
