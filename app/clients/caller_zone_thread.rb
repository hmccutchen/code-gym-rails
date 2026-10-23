module CallerZoneThread
  # Time.zone is per thread; carry the caller's zone so every ApiUsage row of one fan-out lands on the same date.
  def self.start(&work)
    zone = Time.zone
    Thread.new { Time.use_zone(zone, &work) }
  end
end
