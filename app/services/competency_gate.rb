# How many sections a day may hold, earned from reviewed work. Folds over
# past days oldest first, so its answer is a pure function of stored evidence
# and an earlier day's answer never changes when a later day is added. The
# fold is pure, plain values in and a Plan out; only .for reads the database,
# through Evidence.
#
# These thresholds are a starting policy, not values validated against
# history: the AI rating's level calibration is unverified, which is why a
# result is favourable only when the engineer's own rating agrees.
class CompetencyGate
  Threshold = Data.define(:at_least, :of) do
    def met?(window, &qualifies) = window.size == of && window.count(&qualifies) >= at_least
  end

  BAR = "solid"
  GROW_TO_THREE = Threshold.new(at_least: 4, of: 5)
  GROW_TO_FOUR = Threshold.new(at_least: 8, of: 10)
  OPTIONAL_RUN = 2
  BRAKE = Threshold.new(at_least: 2, of: 4)

  FLOOR = SectionCount::FLOOR
  GROWTH = [ GROW_TO_THREE, GROW_TO_FOUR ].freeze

  # :none, the day had no optional section; :incomplete, it left at least one
  # unanswered; :complete, it answered every one.
  OPTIONAL_STATES = %i[none incomplete complete].freeze

  # Results are ReviewedSectionResults::Result values, eased ones included,
  # in the order the day presented them.
  Day = Data.define(:results, :optional) do
    def initialize(results:, optional:)
      raise ArgumentError, "optional must be one of #{OPTIONAL_STATES.inspect}, not #{optional.inspect}" unless
        OPTIONAL_STATES.include?(optional)

      super
    end
  end

  # evidence is nil unless the caller asked for it.
  Plan = Data.define(:count, :reason, :evidence)

  Entry = Data.define(:sequence, :result)
  private_constant :Entry

  # The longest window each rule reads; older results in a run can never matter.
  GROWTH_MEMORY = GROWTH.map(&:of).max
  private_constant :GROWTH_MEMORY

  def self.for(user)
    plan(Evidence.new(user), fixed_kinds: ExerciseSection.fixed.map(&:key))
  end

  def self.plans(days, fixed_kinds:, evidence: false)
    gate = new(fixed_kinds: fixed_kinds)
    days.map { |day| gate.add(day).plan(evidence: evidence) }
  end

  def self.plan(days, fixed_kinds:)
    gate = new(fixed_kinds: fixed_kinds)
    days.each { |day| gate.add(day) }
    gate.plan
  end

  def initialize(fixed_kinds:)
    @fixed_kinds = fixed_kinds
    @levels = {}
    @growth_runs = {}
    @brake_runs = {}
    @optional_days = []
    @sequence = 0
    @count = FLOOR
    @reason = :held
  end

  def add(day)
    day.results.each { |result| record(result) }
    @optional_days = (@optional_days + [ day.optional ]).last(OPTIONAL_RUN) unless day.optional == :none
    @count, @reason = next_step
    restart_growth if @reason == :brake
    self
  end

  def plan(evidence: true)
    Plan.new(count: @count.clamp(FLOOR, ExerciseSection::MAX_SECTIONS), reason: @reason,
             evidence: (self.evidence if evidence))
  end

  def evidence
    braking = brake_window
    {
      to_three: growth_evidence(GROW_TO_THREE),
      to_four: growth_evidence(GROW_TO_FOUR),
      brake: { required: BRAKE.of, available: braking.size, too_hard: braking.count(&:too_hard?) },
      optional: { required: OPTIONAL_RUN, available: @optional_days.size, complete: @optional_days.count(:complete) },
      levels: @levels.dup
    }
  end

  private

  # A kind whose level changed starts a new run, even back at a level it held
  # before: evidence earned at a rung belongs to that stretch of work. An eased
  # section answered an easier question than its rung, so its AI rating never
  # enters growth, but its self-rating still counts toward the brake.
  def record(result)
    reset_runs(result.kind) if @levels.key?(result.kind) && @levels[result.kind] != result.level
    @levels[result.kind] = result.level
    entry = Entry.new(sequence: @sequence += 1, result: result)
    append(@brake_runs, result.kind, entry, BRAKE.of)
    append(@growth_runs, result.kind, entry, GROWTH_MEMORY) unless result.eased
  end

  def reset_runs(kind)
    @brake_runs[kind] = []
    @growth_runs[kind] = []
  end

  def append(runs, kind, entry, memory)
    runs[kind] = (runs.fetch(kind, []) + [ entry ]).last(memory)
  end

  # After a brake, growth needs a full window of results that came after it,
  # so struggling on optional sections cannot swing the day back up the next
  # day on fixed-kind results earned before the struggle.
  def restart_growth
    @growth_runs.transform_values! { [] }
  end

  def next_step
    if BRAKE.met?(brake_window, &:too_hard?)
      [ FLOOR, :brake ]
    elsif @count == FLOOR && grows?(GROW_TO_THREE)
      [ @count + 1, :grew ]
    elsif @count == FLOOR + 1 && grows?(GROW_TO_FOUR) && optional_run_complete?
      [ @count + 1, :grew ]
    else
      [ @count, :held ]
    end
  end

  def grows?(threshold)
    threshold.met?(fixed_window(threshold)) { |result| result.favourable?(bar: BAR) }
  end

  def optional_run_complete?
    @optional_days.size == OPTIONAL_RUN && @optional_days.all?(:complete)
  end

  def brake_window = latest(@brake_runs, BRAKE.of, @brake_runs.keys)
  def fixed_window(threshold) = latest(@growth_runs, threshold.of, @fixed_kinds)

  def latest(runs, size, kinds)
    kinds.flat_map { |kind| runs.fetch(kind, []) }.max_by(size, &:sequence).map(&:result)
  end

  def growth_evidence(threshold)
    window = fixed_window(threshold)
    { required: threshold.of, available: window.size,
      bar_met: window.count { |result| result.at_or_above?(BAR) },
      favourable: window.count { |result| result.favourable?(bar: BAR) },
      by_kind: window.map(&:kind).tally }
  end
end
