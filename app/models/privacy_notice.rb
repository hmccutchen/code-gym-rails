# Design notes: docs/code-notes/app/models/privacy_notice.md
module PrivacyNotice
  BACKUP_DAYS = 6
  LOG_DAYS = 7

  def self.facts
    { backup_days: BACKUP_DAYS, log_days: LOG_DAYS, duck_days: DuckThread::KEPT_FOR.in_days.to_i,
      unopened_sets: UnopenedSets::PAUSE_AFTER, cache_days: cache_days, session_days: session_days }
  end

  def self.cache_days
    @cache_days ||= days_rounded_up(Rails.application.config_for(:cache).dig(:store_options, :max_age))
  end

  def self.session_days = days_rounded_up(Rails.application.config.session_options.fetch(:expire_after))

  def self.days_rounded_up(seconds) = (seconds / 1.day.to_f).ceil
end
