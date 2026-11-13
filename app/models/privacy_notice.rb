# Design notes: docs/code-notes/app/models/privacy_notice.md
module PrivacyNotice
  BACKUP_DAYS = 6
  LOG_DAYS = 7

  def self.facts
    { backup_days: BACKUP_DAYS, log_days: LOG_DAYS, duck_days: DuckThread::KEPT_FOR.in_days.to_i,
      unopened_sets: UnopenedSets::PAUSE_AFTER, cache_days: cache_days }
  end

  def self.cache_days
    Rails.application.config_for(:cache).dig(:store_options, :max_age) / 1.day.to_i
  end
end
