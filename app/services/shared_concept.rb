# The concept both fixed sections take on one day. Pure: reinforcement
# entries, the day's due checks, a DayHosts and the day's kinds.
class SharedConcept
  # A reduced-tier concept has stalled across several reviews, so every fixed
  # section takes it, each from its own side. Paused concepts never reach the
  # reinforcement list. The pairing only ever fills hosts nothing else
  # needed: it is made only when every other reinforcement entry and due
  # check can still take a distinct remaining kind able to tag it, so a
  # concept whose only hosts are the fixed sections is never displaced.
  # Returns the entry, or nil.
  def self.pick(reinforcement, due_checks, hosts, kinds:)
    remaining = kinds.reject(&:fourth?) - ExerciseSection.fixed
    checks    = due_checks.map { |cm| [ cm.concept, cm.language ] }

    reinforcement.find do |h|
      h[:tier] == "reduced" && ExerciseSection.fixed.all? { |kind| hosts.can_tag?(kind, h[:concept], h[:bucket]) } &&
        placeable?(checks + (reinforcement - [ h ]).map { |o| [ o[:concept], o[:bucket] ] }, remaining, hosts)
    end
  end

  # Whether each [concept, bucket] can take a different kind that tags it.
  def self.placeable?(concepts, kinds, hosts)
    return true if concepts.empty?

    (concept, bucket), *rest = concepts
    kinds.any? { |kind| hosts.can_tag?(kind, concept, bucket) && placeable?(rest, kinds - [ kind ], hosts) }
  end
  private_class_method :placeable?
end
