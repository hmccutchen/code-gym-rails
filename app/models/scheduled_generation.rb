module ScheduledGeneration
  START_HOUR = 8

  def self.users
    User.active.where.not(api_keys: nil).where(paused_generation_at: nil).where(generation_account_failures: KeyHold::COVERED_COUNTS)
  end

  def self.due?(user, at: Time.current)
    local = at.in_time_zone(user.effective_time_zone)
    local.on_weekday? && local.hour >= START_HOUR
  end
end
