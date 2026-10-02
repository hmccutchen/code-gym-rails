# The concept both fixed sections take on one day, and what that costs the
# rest of reinforcement. Pure: reinforcement entries and a DayHosts in.
class SharedConcept
  # One entry fills every fixed section, so it takes this many hosts.
  HOSTS = ExerciseSection.fixed.size

  # A reduced-tier concept has stalled across several reviews, so both fixed
  # sections take it, each from its own side. Paused concepts never reach
  # the reinforcement list. Returns the entry, or nil.
  def self.pick(reinforcement, hosts)
    reinforcement.find do |h|
      h[:tier] == "reduced" && ExerciseSection.fixed.all? { |kind| hosts.can_tag?(kind, h[:concept], h[:bucket]) }
    end
  end

  # Reinforcement cut to `hosts`, and the shared entry if it still fits.
  # When it does not, the concept stays ordinary reinforcement.
  def self.fit(reinforcement, shared, hosts)
    return [ reinforcement.first(hosts), nil ] if shared.nil? || hosts < HOSTS

    others = (reinforcement - [ shared ]).first(hosts - HOSTS)
    [ reinforcement & [ shared, *others ], shared ]
  end

  def self.hosts_taken(reinforcement, shared)
    reinforcement.size + (shared ? HOSTS - 1 : 0)
  end
end
