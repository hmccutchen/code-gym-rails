class PracticeSchedule::Turns
  CYCLE = 3
  INITIAL_REVIEWED_SETS = 2
  Result = Data.define(:kinds, :rotation, :note)

  def self.plan(**options) = new(**options).plan

  def initialize(context:, count:, setting:, daily:, regular:, preferences:, evidence:, hosts:, rotation_history:, due:, drills:)
    @previous = context ? PracticeSchedule::Note.decode(context) : {}
    @count, @setting, @daily, @preferences = count, setting, daily, preferences
    @regular = regular
    @evidence, @hosts, @history, @due, @drills = evidence, hosts, rotation_history, due, drills
    @continuation = @previous.fetch("continuation", {
      "next_phase" => 0, "kind_order" => [], "next_kind_index" => 0, "last_omitted_kind" => nil, "service" => {}
    }).deep_dup
  end

  def plan
    order_pool
    ready = @previous["initial_ready"] || @evidence.fetch(:initial_reviewed_sets) >= INITIAL_REVIEWED_SETS
    rotation = SectionRotation.for(@history, count: @count, daily: @daily, preferences: @preferences)
    kinds = ExerciseSection.for_plan(daily: @daily, rotation: rotation)
    phase = @continuation["next_phase"] if recurring?(ready)
    omitted = nil
    if phase == 0 && @continuation["kind_order"].any?
      omitted = omission
      replacement = ExerciseSection.for(@continuation["kind_order"].fetch(@continuation["next_kind_index"]))
      kinds = (@daily - [ omitted ]) + [ replacement ]
      rotation = rotation.merge(ExerciseSection.slot_for(replacement, daily: @daily) => replacement.key.to_sym)
      @continuation["next_kind_index"] = (@continuation["next_kind_index"] + 1) % @continuation["kind_order"].size
      @continuation["last_omitted_kind"] = omitted.key
    end
    @continuation["next_phase"] = (phase + 1) % CYCLE unless phase.nil?
    note = { "version" => 1, "policy" => 2, "sequence" => @previous.fetch("sequence", 0) + 1,
      "initial_ready" => !!ready, "regular_kinds" => @regular.map(&:key), "phase" => phase,
      "selected_kinds" => kinds.map(&:key), "assignments" => {}, "continuation" => @continuation }
    note["omitted_kind"] = omitted.key if omitted
    Result.new(kinds: kinds, rotation: rotation, note: note)
  end

  private

  def recurring?(ready)
    ready && @setting.nil? && @count == DailyKinds::COUNT &&
      (@previous.empty? || @previous["regular_kinds"] == @regular.map(&:key))
  end

  def omission
    struggling = @daily.select { |kind| @evidence.fetch(:struggle)[kind.key] == true }
    return (@daily - struggling).sole if struggling.one?

    previous = @continuation["last_omitted_kind"]
    return @daily.last unless @daily.any? { |kind| kind.key == previous }

    @daily.find { |kind| kind.key != previous }
  end

  def order_pool
    pool = ExerciseSection.optional_slots(daily: @regular).values.flatten.reject { |kind| @preferences.excluded?(kind) }
    old = @continuation["kind_order"]
    last = old.any? ? old[(@continuation["next_kind_index"] - 1) % old.size] : nil
    survivors = old & pool.map(&:key)
    additions = seed(pool.reject { |kind| survivors.include?(kind.key) }).map(&:key)
    order = survivors + additions
    @continuation["kind_order"] = order
    @continuation["next_kind_index"] = last && survivors.include?(last) ? (order.index(last) + 1) % order.size : 0
  end

  def seed(kinds)
    kinds.group_by { |kind| [ priority(kind), last_seen(kind) ] }.sort_by(&:first).flat_map do |_priority, group|
      ordered = []
      until group.empty?
        chosen = WeightedRoll.pick(group.index_with { |kind| @preferences.multiplier_for(kind) })
        ordered << chosen
        group = group - [ chosen ]
      end
      ordered
    end
  end

  def last_seen(kind)
    index = @history.index { |entry| entry.section_keys.include?(kind.key) }
    index ? -index : -Float::INFINITY
  end

  def priority(kind)
    requests = @evidence.fetch(:pending).select { |entry| entry[:kind] == kind.key && @hosts.can_tag?(kind, entry[:concept], entry[:bucket]) }
    return 0 if requests.any? { |entry| entry[:mode] == "normal_retry" }
    return 1 if requests.any?
    return 2 if @due.any? { |entry| @hosts.can_tag?(kind, entry[:concept], entry[:bucket]) }
    return 3 if @drills.any? { |entry| @hosts.can_tag?(kind, entry[:concept], entry[:bucket]) }

    4
  end
end
