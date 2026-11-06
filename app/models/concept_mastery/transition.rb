class ConceptMastery::Transition
  FIELDS = %w[tier streak last_rating cooldown_remaining mastered_at retention_interval_days next_retention_check_on drilled_at drill_group].freeze

  def self.apply(state, operation)
    new(state.deep_dup, operation).apply
  end

  def initialize(state, operation)
    @state = state
    @operation = operation
  end

  def apply
    case @operation.fetch("type")
    when "review" then review
    when "session" then count_down
    when "skip" then defer_check
    when "drill" then drill
    else raise ArgumentError, "Unknown mastery operation"
    end
    @state
  end

  private

  def review
    return if @state.fetch("tier") == "paused"

    evidence = @operation.fetch("sections").values
    grade = evidence.map { |value| value.fetch("rating") }.min_by { |value| ConceptMastery::AI_RATING_RANK.fetch(value) }
    favourable = evidence.all? { |value| DailyResponse::SELF_RATING_FAVORABLE.include?(value["self_rating"]) }
    if favourable && DailyResponse::AI_RATING_FAVORABLE.include?(grade)
      master
    else
      struggle(grade)
    end
    @state["last_rating"] = grade
  end

  def master
    interval = retention_interval
    @state.merge!("tier" => "standard", "streak" => 0, "cooldown_remaining" => 0,
      "drilled_at" => nil, "drill_group" => nil,
      "mastered_at" => @state["mastered_at"] || @operation.fetch("occurred_at"),
      "retention_interval_days" => interval,
      "next_retention_check_on" => (Date.iso8601(@operation.fetch("reviewed_on")) + interval).iso8601)
  end

  def retention_interval
    interval = @state["retention_interval_days"]
    return ConceptMastery::RETENTION_INITIAL_INTERVAL_DAYS if interval.nil?
    return interval unless due?

    [ interval * ConceptMastery::RETENTION_GROWTH_FACTOR, ConceptMastery::RETENTION_MAX_INTERVAL_DAYS ].min
  end

  def due?
    @state["next_retention_check_on"] && Date.iso8601(@state["next_retention_check_on"]) <= Date.iso8601(@operation.fetch("work_on"))
  end

  def struggle(grade)
    previous = @state["last_rating"]
    improving = previous.present? && ConceptMastery::AI_RATING_RANK.fetch(grade) > ConceptMastery::AI_RATING_RANK.fetch(previous, -1)
    @state.merge!("next_retention_check_on" => nil, "retention_interval_days" => nil)
    @state["streak"] = improving || previous.blank? ? 0 : @state.fetch("streak") + 1
    if @state.fetch("tier") == "standard" && @state.fetch("streak") >= 3
      @state.merge!("tier" => "reduced", "streak" => 0)
    elsif @state.fetch("tier") == "reduced" && @state.fetch("streak") >= 2
      @state.merge!("tier" => "paused", "streak" => 0, "cooldown_remaining" => 2)
    end
  end

  def count_down
    return unless @state.fetch("tier") == "paused"

    @state["cooldown_remaining"] -= 1
    end_pause if @state.fetch("cooldown_remaining") <= 0
  end

  def end_pause
    @state.merge!("tier" => "reduced", "streak" => 0, "cooldown_remaining" => 0)
  end

  def defer_check
    interval = @state["retention_interval_days"]
    return unless interval&.positive? && due?

    day = [ @operation.fetch("reviewed_on"), @operation.fetch("work_on") ].map { |value| Date.iso8601(value) }.max
    @state["next_retention_check_on"] = (day + interval).iso8601
  end

  def drill
    case @operation.fetch("action")
    when "clear"
      @state.merge!("drilled_at" => nil, "drill_group" => nil)
    when "set"
      end_pause if @operation.fetch("end_pause") && @state.fetch("tier") == "paused"
      @state.merge!(@operation.slice("drilled_at", "drill_group"))
    else raise ArgumentError, "Unknown mastery drill action"
    end
  end
end
