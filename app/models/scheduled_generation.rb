module ScheduledGeneration
  START_HOUR = 8

  def self.users = User.active.where.not(api_keys: nil).where(paused_generation_at: nil)

  # Reads the clock in Time.zone, so the caller sets the user's zone first.
  def self.due_now? = Date.current.on_weekday? && Time.current.hour >= START_HOUR
end
