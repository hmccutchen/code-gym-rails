class GenerateDailyExercisesJob < ApplicationJob
  queue_as :default

  # Called two ways:
  #   1. Cron (no args) — runs hourly; generates for users whose local time is
  #      a weekday morning at/after 8am, one exercise per local day
  #   2. On-demand (user_id:) — generates for one user when they first open the app
  def perform(user_id: nil)
    if user_id
      # On-demand: the dashboard already gated weekday; generate in the user's
      # zone with no hour gate (a user opening the app early still gets today's).
      # `active` guards a job enqueued before deletion or retried afterward, so
      # an anonymized user is never processed.
      User.active.where(id: user_id).find_each do |user|
        Time.use_zone(user.effective_time_zone) { generate_now(user) }
      end
    else
      # Hourly batch: each user in their own zone, gated to local weekday morning.
      # A user with paused_generation_at set is skipped here only — the
      # on-demand path (user_id given, above) still generates for them.
      User.active.where.not(api_key: nil).where(paused_generation_at: nil).find_each do |user|
        Time.use_zone(user.effective_time_zone) { generate_if_due(user) }
      end
    end
  end

  private

  # Batch gate: local weekday, local hour >= 8, and not already generated today.
  def generate_if_due(user)
    return unless Date.current.on_weekday?
    return unless Time.current.hour >= 8
    generate_now(user)
  end

  # Generate today's (local) exercise unless it already exists.
  def generate_now(user)
    return if DailyExercise.exists?(user: user, date: Date.current)
    generate_for(user)
  end

  # On completion (success or failure), the dashboard learns the outcome by
  # polling GET /dashboard/status (DashboardController#status) and reloading
  # — this app loads no Turbo/Stimulus JS, so a live broadcast here would
  # have no subscriber.
  def generate_for(user)
    language    = user.language_for_today
    problem_set = AiService.for(user).generate_exercise(user, language: language)

    DailyExercise.create!(
      user:         user,
      date:         Date.current,
      problem_set:  problem_set,
      generated_at: Time.current,
      language:     language
    )

    # Defense-in-depth: #status/#show both check exercise-existence before
    # these columns, so this isn't load-bearing today, but clears the slate
    # for any future reader that checks these columns directly.
    user.update!(last_generation_error_date: nil, last_generation_error: nil) if user.last_generation_error_date.present?

    Rails.logger.info("Generated exercise for #{user.email} on #{Date.current}")
  rescue AiService::AuthenticationError => e
    Rails.logger.error("Auth failure generating exercise for #{user.email}: #{e.message}")
    persist_failure(user, "Your API key was rejected — check it in Settings.")
  rescue AiService::RateLimitError => e
    Rails.logger.warn("Rate limited generating exercise for #{user.email}: #{e.message}")
    persist_failure(user, "The AI provider is rate-limiting requests — try again shortly.")
  rescue AiService::Error => e
    Rails.logger.error("Failed to generate exercise for #{user.email}: #{e.message}")
    persist_failure(user, e.message)
    # Don't re-raise — one failure shouldn't block other users in the batch
  rescue ActiveRecord::RecordNotUnique
    # Lost a race against a concurrent generation for this user/date (e.g. two
    # dashboard loads both finding no exercise before either could create
    # one). The other one won; nothing to do here.
    Rails.logger.info("Skipped duplicate generation for #{user.email} on #{Date.current} (already generated concurrently)")
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors[:date].present?
    Rails.logger.info("Skipped duplicate generation for #{user.email} on #{Date.current} (already generated concurrently)")
  end

  def persist_failure(user, message)
    user.update!(last_generation_error_date: Date.current, last_generation_error: message)
  end
end
