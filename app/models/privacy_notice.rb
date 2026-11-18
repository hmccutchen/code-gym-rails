# Design notes: docs/code-notes/app/models/privacy_notice.md
module PrivacyNotice
  LOG_DAYS = 7

  def self.facts
    { log_days: LOG_DAYS, duck_days: DuckThread::KEPT_FOR.in_days.to_i,
      unopened_sets: UnopenedSets::PAUSE_AFTER, session_days: session_days,
      note_days: LearnerNote::KEPT_FOR.in_days.to_i, item_days: LearnerItem::KEPT_AFTER_CLOSE.in_days.to_i,
      item_lookback_days: LearnerItem::RECENT_DAYS, open_items: LearnerItem::MAX_OPEN, listed_closed_days: LearnerItem::RECENT_DAYS }
  end

  def self.session_days = days_rounded_up(Rails.application.config.session_options.fetch(:expire_after))

  def self.days_rounded_up(seconds) = (seconds / 1.day.to_f).ceil
end
