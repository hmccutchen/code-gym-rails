class CompetencyGate
  class Capacity
    def initialize
      @full = @skips = @comfortable = 0
      @recovery = @skip_hold = false
    end

    def record(completion, count:)
      @last = completion.state
      if actual_skip?(completion, count)
        @full = @comfortable = 0
        @skips = [ @skips + 1, SKIP_RUN ].min
        @skip_hold = true
      elsif sufficient_full?(completion, count)
        @full = [ @full + 1, FULL_RUN ].min
        @skips = 0
        @skip_hold = false if @full == FULL_RUN
        recover(completion) if @recovery
      elsif completion.state == :complete && (completion.assigned || count) == count
        @skips = 0
      end
    end

    def skipping? = @skips == SKIP_RUN
    def safety_hold? = @recovery || @skip_hold
    def ready? = @full == FULL_RUN && !safety_hold?

    def grow
      @full = @skips = 0
      @skip_hold = false
    end

    def reduce
      grow
      @comfortable = 0
      @recovery = true
    end

    def evidence
      { full_run: @full, skip_run: @skips, recovery: @recovery, comfortable_run: @comfortable,
        safety_hold: safety_hold?, last_completion: @last }
    end

    private

    def actual_skip?(completion, count)
      completion.state == :incomplete && (completion.assigned.nil? || completion.assigned == count)
    end

    def sufficient_full?(completion, count)
      target = completion.assigned || count
      completion.state == :complete && target >= count && completion.delivered >= target
    end

    def recover(completion)
      return unless completion.ratings_known

      @comfortable = completion.too_hard.size < OVERLOAD_KINDS ? [ @comfortable + 1, FULL_RUN ].min : 0
      @recovery = false if @comfortable == FULL_RUN
    end
  end
end
