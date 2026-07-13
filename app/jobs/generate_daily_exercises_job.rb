class GenerateDailyExercisesJob < ApplicationJob
  queue_as :default

  # Called two ways:
  #   1. Cron (no args) — generates for ALL users at 8am weekdays
  #   2. On-demand (user_id:) — generates for one user when they first open the app
  def perform(user_id: nil)
    users = user_id ? User.where(id: user_id) : User.where.not(api_key: nil)

    users.find_each do |user|
      next if DailyExercise.exists?(user: user, date: Date.current)

      generate_for(user)
    end
  end

  private

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

    Rails.logger.info("Generated exercise for #{user.email} on #{Date.current}")
  rescue AiService::Error => e
    Rails.logger.error("Failed to generate exercise for #{user.email}: #{e.message}")
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
end
