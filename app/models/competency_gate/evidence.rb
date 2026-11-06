class CompetencyGate
  # No cap: the fold keeps an earned size until something undoes it, so a recent window would forget it. Batches bound memory.
  class Evidence
    include Enumerable

    BATCH_SIZE = 100

    def initialize(user, batch_size: BATCH_SIZE)
      @user = user
      @batch_size = batch_size
    end

    def each
      return enum_for(:each) unless block_given?

      responses.find_in_batches(cursor: %i[date id], batch_size: @batch_size) do |batch|
        batch.each do |response|
          day = day_for(response)
          yield day if day
        end
      end
    end

    private

    def responses
      ReviewedSectionResults.with_current_rubric(@user.daily_responses.submitted.reviewed).preload(:daily_exercise)
    end

    def day_for(response)
      return unless response.assessed_sections.any? { |section| ReviewedSectionResults.current_rubric?(response.ai_review[section]) }

      daily = response.daily_exercise.daily_kinds.map(&:key)
      results = ReviewedSectionResults.for(response, require_rubric: true, include_eased: true)
      day = Day.new(results: results, optional: optional_state(response, daily), daily: daily)
      day if day.evidence?
    end

    def optional_state(response, daily)
      optional = response.section_keys - daily
      return :none if optional.empty?
      return :unknown unless response.completion_evidence?

      (optional - response.answered_sections).empty? ? :complete : :incomplete
    end
  end
end
