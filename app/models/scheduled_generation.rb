module ScheduledGeneration
  START_HOUR = 8
  KEY_HOLD_KINDS = %w[bad_key out_of_credit].freeze
  KEY_HOLD_AFTER = 2

  def self.users
    User.active.where.not(api_keys: nil).where(paused_generation_at: nil).where(generation_account_failures: ...KEY_HOLD_AFTER)
  end

  def self.key_hold_kind?(kind) = KEY_HOLD_KINDS.include?(kind)

  def self.due?(user, at: Time.current)
    local = at.in_time_zone(user.effective_time_zone)
    local.on_weekday? && local.hour >= START_HOUR
  end
end
