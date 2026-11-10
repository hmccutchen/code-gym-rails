module CallerZoneThread
  # Time.zone is per thread; carry the caller's zone so every ApiUsage row of one fan-out lands on the same date.
  def self.start(&work)
    zone = Time.zone
    # archspec:disable-next-line constants.forbid -- the one place a fan-out thread starts
    Thread.new { Time.use_zone(zone, &work) }
  end
end
