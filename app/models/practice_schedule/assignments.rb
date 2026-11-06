class PracticeSchedule::Assignments
  PRACTICE_PRIORITY = %w[normal_retry simplified support reinforcement].freeze

  def self.plan(**options) = new(**options).plan

  def initialize(kinds:, hosts:, pending:, reinforcement:, due:, drills:, service:, sequence:)
    @kinds, @hosts, @service, @sequence = kinds, hosts, service.deep_dup, sequence
    @practice = pending.map { |entry| entry.merge(reason: entry.fetch(:mode)) } +
      reinforcement.map { |entry| entry.merge(reason: "reinforcement", mode: entry[:tier] == "reduced" ? "simplified" : "normal") }
    @maintenance = due.map { |entry| entry.merge(reason: "retention", mode: "normal") } +
      drills.map { |entry| entry.merge(reason: "drill", mode: entry[:tier] == "reduced" ? "simplified" : "normal") }
  end

  def plan
    choices = @kinds.to_h { |kind| [ kind.key, choices_for(kind) ] }
    order = @kinds.sort_by { |kind| [ constrained?(kind) ? 0 : 1, choices.fetch(kind.key).size ] }.map(&:key)
    assigned = SharedConcept.match(choices.slice(*order)) { |entry| identity(entry) }
    update_service(assigned)
    [ assigned.to_h { |key, entry| [ key, entry.merge(kind: key) ] }, @service ]
  end

  private

  def eligible?(kind, entry)
    (!entry[:kind] || entry[:kind] == kind.key) && @hosts.can_tag?(kind, entry[:concept], entry[:bucket])
  end

  def constrained?(kind) = @practice.any? { |entry| entry[:kind] == kind.key && eligible?(kind, entry) }

  def choices_for(kind)
    practice = @practice.select { |entry| eligible?(kind, entry) }.sort_by do |entry|
      [ last_service(kind.key, entry), PRACTICE_PRIORITY.index(entry[:reason]), entry.fetch(:requested_at, ""),
        ConceptBucket.vocabulary_for(entry[:bucket]).index(entry[:concept]) ]
    end
    maintenance = @maintenance.select { |entry| eligible?(kind, entry) }
    preferred = @service.dig(kind.key, "last_maintenance") == "retention" ? "drill" : "retention"
    maintenance = maintenance.each_with_index.sort_by do |entry, index|
      [ entry[:reason] == preferred ? 0 : 1, -entry.fetch(:overdue_ratio, 0), index ]
    end.map(&:first)
    spare_for_maintenance?(kind, maintenance) || @service.dig(kind.key, "last_lane") == "practice" ? maintenance + practice : practice + maintenance
  end

  def spare_for_maintenance?(kind, maintenance)
    !constrained?(kind) && @kinds.any? do |other|
      other != kind && constrained?(other) && maintenance.any? { |entry| eligible?(other, entry) }
    end
  end

  def identity(entry)
    [ entry[:kind], entry[:concept], entry[:bucket], entry[:reason].in?(%w[retention drill]) ? "maintenance" : "practice" ]
  end

  def last_service(key, entry)
    records = @service.dig(key, "concepts") || []
    records.find { |record| record.values_at("concept", "bucket") == entry.values_at(:concept, :bucket) }&.fetch("sequence") || 0
  end

  def update_service(assigned)
    @service.each do |key, record|
      relevant = @practice.select { |entry| entry[:kind].nil? || entry[:kind] == key }
      record["concepts"].select! { |entry| relevant.any? { |candidate| candidate.values_at(:concept, :bucket) == entry.values_at("concept", "bucket") } }
    end
    assigned.each do |key, entry|
      record = @service[key] ||= { "last_lane" => nil, "last_maintenance" => nil, "concepts" => [] }
      maintenance = %w[retention drill].include?(entry[:reason])
      record["last_lane"] = maintenance ? "maintenance" : "practice"
      record["last_maintenance"] = entry[:reason] if maintenance
      next if maintenance

      record["concepts"].reject! { |item| item.values_at("concept", "bucket") == entry.values_at(:concept, :bucket) }
      record["concepts"] << { "concept" => entry[:concept], "bucket" => entry[:bucket], "sequence" => @sequence }
    end
  end
end
