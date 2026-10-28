class SharedConcept
  # Pairs only when every other reinforcement entry and due check still gets a distinct kind, so nothing is displaced.
  def self.pick(reinforcement, due_checks, hosts, kinds:, daily:)
    return nil if daily.empty?

    remaining = kinds.reject(&:fourth?) - daily
    checks    = due_checks.map { |cm| [ cm.concept, cm.language ] }

    reinforcement.find do |h|
      h[:tier] == "reduced" && daily.all? { |kind| hosts.can_tag?(kind, h[:concept], h[:bucket]) } &&
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
