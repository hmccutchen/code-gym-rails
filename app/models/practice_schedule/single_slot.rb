class PracticeSchedule::SingleSlot
  def self.plan(**options) = new(**options).plan

  def initialize(context:, daily:, preferences:, evidence:, hosts:, rotation_history:, due:, drills:, replacing: false)
    @previous = PracticeSchedule::Note.decode(context || {})
    @daily, @preferences, @evidence, @hosts = daily, preferences, evidence, hosts
    @history, @due, @drills, @replacing = rotation_history, due, drills, replacing
    @sequence = @previous.fetch("sequence", @history.size)
    @continuation = continuation
  end

  def plan
    pool = @preferences.offered(daily: @daily)
    original = @previous.fetch("selected_kinds", []).map { |key| ExerciseSection.for(key) }
    kind = @replacing && original.one? && pool.include?(original.first) ? original.first : choose(pool)
    sequence = @replacing ? [ @sequence, 1 ].max : @sequence + 1
    (@continuation["kind_service"][@hosts.language] ||= {})[kind.key] = sequence unless @replacing
    note = { "version" => 3, "policy" => 2, "sequence" => sequence,
      "initial_ready" => !!(@previous["initial_ready"] || @evidence.fetch(:initial_reviewed_sets) >= PracticeSchedule::Turns::INITIAL_REVIEWED_SETS),
      "regular_kinds" => @daily.map(&:key), "selected_kinds" => [ kind.key ],
      "assignments" => {}, "continuation" => @continuation }
    rotation = ExerciseSection.optional_slots(daily: @daily).transform_values { |options| kind.key.to_sym if options.include?(kind) }
    PracticeSchedule::Turns::Result.new(kinds: [ kind ], rotation: rotation, note: note)
  end

  private

  def continuation
    service = @previous["version"] == 3 ? @previous.dig("continuation", "service") : legacy_service
    kinds = @previous["version"] == 3 ? @previous.dig("continuation", "kind_service").deep_dup : {}
    kinds[@hosts.language] ||= historical_service unless @replacing && @previous["version"] == 3
    { "kind_service" => kinds, "service" => service.deep_dup }
  end

  def legacy_service
    service = @previous.dig("continuation", "service") || {}
    DailyExercise::LANGUAGES.to_h do |language|
      records = service.to_h do |kind, record|
        concepts = record.fetch("concepts").select { |entry| entry["bucket"] == ConceptBucket.for(kind, language) }
        [ kind, { "last_lane" => nil, "last_maintenance" => nil, "concepts" => concepts } ]
      end
      [ language, records ]
    end
  end

  def historical_service
    @history.each_with_index.with_object({}) do |(entry, index), service|
      entry.delivered_section_keys.each { |key| service[key] ||= [ @sequence - index, 0 ].max }
    end
  end

  def choose(pool)
    raise ArgumentError, "No eligible practice kind" if pool.empty?

    groups = pool.group_by { |kind| [ @continuation["kind_service"].fetch(@hosts.language, {}).fetch(kind.key, 0), priority(kind), @daily.include?(kind) ? 0 : 1 ] }
    candidates = groups.fetch(groups.keys.min)
    WeightedRoll.pick(candidates.index_with { |kind| @daily.include?(kind) ? KindPreferences::DEFAULT_MULTIPLIER : @preferences.multiplier_for(kind) })
  end

  def priority(kind)
    pending = @evidence.fetch(:pending).select { |entry| eligible?(kind, entry) }
    return 0 if pending.any? { |entry| entry[:mode] == "normal_retry" }
    return 1 if pending.any? || (@hosts.planning_host?(kind) && @evidence.fetch(:struggle, {})[kind.key])
    return 2 if @evidence.fetch(:reinforcement, []).any? { |entry| eligible?(kind, entry) }
    return 3 if @due.any? { |entry| eligible?(kind, entry) }
    return 4 if @drills.any? { |entry| eligible?(kind, entry) }

    5
  end

  def eligible?(kind, entry)
    (!entry[:kind] || entry[:kind] == kind.key) && @hosts.can_tag?(kind, entry[:concept], entry[:bucket])
  end
end
