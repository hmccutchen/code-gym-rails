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
  RATING_SCALE = (DailyResponse::AI_RATING_UNFAVORABLE + DailyResponse::AI_RATING_FAVORABLE).freeze

  # :none, the day had no optional section; :incomplete, it left at least one
  # unanswered; :complete, it answered every one.
  OPTIONAL_STATES = %i[none incomplete complete].freeze

  # Results respond to kind, level, ai_rating and self_rating, in the order
  # the day presented them.
  Day = Data.define(:results, :optional) do
    def initialize(results:, optional:)
      raise ArgumentError, "optional must be one of #{OPTIONAL_STATES.inspect}, not #{optional.inspect}" unless
        OPTIONAL_STATES.include?(optional)

      super
    end
  end

  Plan = Data.define(:count, :reason, :evidence)

  Entry = Data.define(:sequence, :result)
  private_constant :Entry

  # The longest window any rule reads; older results in a run can never matter.
  RUN_MEMORY = [ *GROWTH, BRAKE ].map(&:of).max
  private_constant :RUN_MEMORY

  def self.for(user)
    plan(Evidence.new(user), fixed_kinds: ExerciseSection.fixed.map(&:key))
  end

  def self.plans(days, fixed_kinds:)
    gate = new(fixed_kinds: fixed_kinds)
    days.map { |day| gate.add(day) }
  end

  def self.plan(days, fixed_kinds:)
    gate = new(fixed_kinds: fixed_kinds)
    days.each { |day| gate.add(day) }
    gate.plan
  end

  attr_reader :plan

  def initialize(fixed_kinds:)
    @fixed_kinds = fixed_kinds
    @levels = {}
    @runs = {}
    @optional_days = []
    @sequence = 0
    @plan = decide(FLOOR, :held)
  end

  def add(day)
    day.results.each { |result| record(result) }
    @optional_days = (@optional_days + [ day.optional ]).last(OPTIONAL_RUN) unless day.optional == :none
    @plan = next_plan
  end

  private

  # A kind whose level changed starts a new run, even back at a level it held
  # before: evidence earned at a rung belongs to that stretch of work.
  def record(result)
    @runs[result.kind] = [] if @levels.key?(result.kind) && @levels[result.kind] != result.level
    @levels[result.kind] = result.level
    @runs[result.kind] = (@runs.fetch(result.kind, []) + [ Entry.new(sequence: @sequence += 1, result: result) ]).last(RUN_MEMORY)
  end

  def next_plan
    count = @plan.count
    if BRAKE.met?(latest(BRAKE.of, @runs.keys)) { |result| too_hard?(result) }
      decide(FLOOR, :brake)
    elsif count == FLOOR && grows?(GROW_TO_THREE)
      decide(count + 1, :grew)
    elsif count == FLOOR + 1 && grows?(GROW_TO_FOUR) && optional_run_complete?
      decide(count + 1, :grew)
    else
      decide(count, :held)
    end
  end

  def decide(count, reason)
    Plan.new(count: count.clamp(FLOOR, ExerciseSection::MAX_SECTIONS), reason: reason, evidence: evidence)
  end

  def grows?(threshold)
    threshold.met?(fixed_window(threshold)) { |result| favourable?(result) }
  end

  def optional_run_complete?
    @optional_days.size == OPTIONAL_RUN && @optional_days.all?(:complete)
  end

  def fixed_window(threshold) = latest(threshold.of, @fixed_kinds)

  def latest(size, kinds)
    kinds.flat_map { |kind| @runs.fetch(kind, []) }.max_by(size, &:sequence).map(&:result)
  end

  def favourable?(result)
    bar_met?(result) && DailyResponse::SELF_RATING_FAVORABLE.include?(result.self_rating)
  end

  def bar_met?(result)
    rank = RATING_SCALE.index(result.ai_rating)
    rank.present? && rank >= RATING_SCALE.index(BAR)
  end

  def too_hard?(result) = result.self_rating == "too_hard"

  def evidence
    brake_window = latest(BRAKE.of, @runs.keys)
    {
      to_three: growth_evidence(GROW_TO_THREE),
      to_four: growth_evidence(GROW_TO_FOUR),
      brake: { required: BRAKE.of, available: brake_window.size, too_hard: brake_window.count { |result| too_hard?(result) } },
      optional: { required: OPTIONAL_RUN, available: @optional_days.size, complete: @optional_days.count(:complete) },
      levels: @levels.dup
    }
  end

  def growth_evidence(threshold)
    window = fixed_window(threshold)
    { required: threshold.of, available: window.size,
      bar_met: window.count { |result| bar_met?(result) },
      favourable: window.count { |result| favourable?(result) },
      by_kind: window.map(&:kind).tally }
  end
end
