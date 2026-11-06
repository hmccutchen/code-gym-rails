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
    choices = concepts.each_with_index.to_h do |(concept, bucket), index|
      [ index, kinds.select { |kind| hosts.can_tag?(kind, concept, bucket) } ]
    end
    match(choices) { |kind| kind }.size == concepts.size
  end
  private_class_method :placeable?

  def self.match(choices, &identity)
    assigned = {}
    choices.each_key { |key| place(key, choices, assigned, [], identity) }
    assigned
  end

  def self.place(key, choices, assigned, visited, identity)
    return false if visited.include?(key)

    choices.fetch(key).each do |entry|
      occupied = assigned.find { |_other, value| identity.call(value) == identity.call(entry) }&.first
      if occupied.nil? || place(occupied, choices, assigned, visited + [ key ], identity)
        assigned[key] = entry
        return true
      end
    end
    false
  end
  private_class_method :place

  def self.on_spare_hosts(assignments, reinforcement, hosts, kinds:, daily:)
    pair = DailyKinds.shared_pair(daily)
    return assignments unless pair.any? && (pair - kinds).empty?

    eligible = reinforcement.select do |entry|
      entry[:tier] == "reduced" && pair.all? do |kind|
        assigned = assignments[kind.key]
        assigned.nil? || (assigned[:reason] == "reinforcement" && assigned.values_at(:concept, :bucket) == entry.values_at(:concept, :bucket))
      end
    end
    shared = pick(eligible, [], hosts, kinds: kinds, daily: pair)
    return assignments unless shared

    assignments.merge(pair.to_h do |kind|
      [ kind.key, shared.merge(kind: kind.key, reason: "reinforcement", mode: "simplified") ]
    end)
  end
end
