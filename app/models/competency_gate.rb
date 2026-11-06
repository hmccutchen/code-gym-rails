class CompetencyGate
  FLOOR = DailyKinds::COUNT
  BAR = ReviewedSectionResults::FAVOURABLE_BAR
  GRADE_WINDOW = 5
  GRADE_SUCCESSES = 4
  EFFORT_WINDOW = 3
  HARD_OBSERVATIONS = 2
  FULL_RUN = 2
  SKIP_RUN = 2
  OVERLOAD_SETS = 3
  OVERLOAD_KINDS = 2

  Completion = Data.define(:state, :assigned, :delivered, :answered, :too_hard, :ratings_known)

  Day = Data.define(:date, :results, :completion, :rungs) do
    def completion_evidence? = %i[complete incomplete].include?(completion.state)
    def evidence? = results.any? || completion_evidence?
  end

  Plan = Data.define(:count, :reason, :safety_hold, :evidence) do
    def reduction? = %i[brake completion].include?(reason)
  end

  def self.for(user, before: Date.current) = plan(Evidence.new(user, before: before))

  def self.plans(days, evidence: false)
    gate = new
    days.map { |day| gate.add(day).plan(evidence: evidence) }
  end

  def self.plan(days)
    gate = new
    days.each { |day| gate.add(day) }
    gate.plan
  end

  def initialize
    @count = FLOOR
    @reason = :held
    @growth_hold = :capacity
    @kinds = {}
    @overload = []
    @capacity = Capacity.new
    @causes = []
  end

  def add(day)
    return self unless day.evidence?
    raise ArgumentError, "evidence dates must increase" if !day.date.is_a?(Date) || (@last_date && day.date <= @last_date)

    @last_date = day.date
    record_kinds(day)
    record_overload(day)
    @capacity.record(day.completion, count: @count) if day.completion_evidence?
    @causes = []
    @causes << :brake if overloaded?
    @causes << :completion if @capacity.skipping?
    @causes.any? ? reduce : advance
    self
  end

  def plan(evidence: true)
    Plan.new(count: @count, reason: @reason, safety_hold: @capacity.safety_hold?,
      evidence: (self.evidence if evidence))
  end

  def evidence
    { kinds: @kinds.transform_values(&:evidence), qualifying_required: qualifying_required,
      capacity: @capacity.evidence.merge(count: @count), overload: @overload.map(&:dup),
      hard_tallies: hard_tallies, causes: @causes.dup, growth_hold: @growth_hold, last_date: @last_date&.to_s,
      last_transition: @last_transition&.to_s }
  end

  private

  def qualifying_required = @count - FLOOR + 1

  def record_kinds(day)
    day.rungs.each { |kind, rung| window(kind).at(rung) }
    day.results.uniq(&:kind).each do |result|
      next if day.rungs.key?(result.kind) && day.rungs[result.kind] != result.level

      window(result.kind).at(result.level).add(result)
    end
  end

  def window(kind) = @kinds[kind] ||= KindWindow.new

  def record_overload(day)
    rated = day.results.uniq(&:kind).select do |result|
      (DailyResponse::SELF_RATING_FAVORABLE + DailyResponse::SELF_RATING_UNFAVORABLE).include?(result.self_rating)
    end
    return if rated.empty?

    @overload = (@overload + [ { date: day.date.to_s, hard: rated.select(&:too_hard?).map(&:kind) } ]).last(OVERLOAD_SETS)
  end

  def hard_tallies = @overload.flat_map { |set| set[:hard] }.tally
  def overloaded? = hard_tallies.count { |_, count| count >= HARD_OBSERVATIONS } >= OVERLOAD_KINDS

  def reduce
    @count = [ @count - 1, FLOOR ].max
    @reason = @causes.first
    @last_transition = @last_date
    @overload = []
    @capacity.reduce
    @growth_hold = :safety
  end

  def advance
    @reason = :held
    @growth_hold = if @count >= ExerciseSection::MAX_SECTIONS
      :maximum
    elsif @capacity.safety_hold?
      :safety
    elsif !@capacity.ready?
      :capacity
    elsif @kinds.count { |_, window| window.qualified? } < qualifying_required
      :kind_proof
    end
    return if @growth_hold

    @count += 1
    @reason = :grew
    @last_transition = @last_date
    @capacity.grow
  end
end
