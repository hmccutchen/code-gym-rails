module CallerZoneThread
  # Time.zone is per thread; carry the caller's zone so every ApiUsage row of one fan-out lands on the same date.
  def self.start(&work)
    zone = Time.zone
    # archspec:disable-next-line constants.forbid -- the one place a fan-out thread starts
    Thread.new { in_executor(zone, &work) }
  end

  # The base executor, not Rails.application.executor: see docs/code-notes/app/clients/caller_zone_thread.md.
  def self.in_executor(zone, &work)
    ActiveSupport::Executor.wrap { Time.use_zone(zone, &work) }
  end
  private_class_method :in_executor
end
