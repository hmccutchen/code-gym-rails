# The concept both fixed sections take on one day. Pure: reinforcement
# entries, a DayHosts and the number of hosts the day left free.
class SharedConcept
  # A reduced-tier concept has stalled across several reviews, so every fixed
  # section takes it, each from its own side. Paused concepts never reach the
  # reinforcement list. The entry already holds one host, so the pairing
  # needs one free host for each further fixed section; it only ever fills a
  # host nothing else wanted. Returns the entry, or nil.
  def self.pick(reinforcement, hosts, spare:)
    return nil if spare < ExerciseSection.fixed.size - 1

    reinforcement.find do |h|
      h[:tier] == "reduced" && ExerciseSection.fixed.all? { |kind| hosts.can_tag?(kind, h[:concept], h[:bucket]) }
    end
  end
end
