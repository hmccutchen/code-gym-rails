class CompetencyGate
  class KindWindow
    def initialize
      @grades = []
      @effort = []
    end

    def at(rung)
      if @rung != rung
        @rung = rung
        @grades = []
        @effort = []
      end
      self
    end

    def add(result)
      @grades = (@grades + [ result ]).last(GRADE_WINDOW) unless result.eased
      observation = effort_for(result)
      @effort = (@effort + [ { date: result.date.to_s, observation: observation } ]).last(EFFORT_WINDOW) if observation
      self
    end

    def successes = @grades.count { |result| result.at_or_above?(BAR) }
    def effort_hard = @effort.count { |entry| entry[:observation] == :hard }
    def effort_blocked? = effort_hard >= HARD_OBSERVATIONS
    def qualified? = @grades.size == GRADE_WINDOW && successes >= GRADE_SUCCESSES && !effort_blocked?

    def evidence
      { rung: @rung, normal_dates: @grades.map { |result| result.date.to_s }, successes: successes,
        normal_required: GRADE_WINDOW, normal_available: @grades.size, effort: @effort.map(&:dup),
        effort_hard: effort_hard, effort_blocked: effort_blocked?, qualified: qualified? }
    end

    private

    def effort_for(result)
      return :hard if result.too_hard?
      return :comfortable if !result.eased && DailyResponse::SELF_RATING_FAVORABLE.include?(result.self_rating)

      nil
    end
  end
end
