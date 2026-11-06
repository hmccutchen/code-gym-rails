class CompetencyGate
  # No cap: the fold keeps an earned size until something undoes it, so a recent window would forget it. Batches bound memory.
  class Evidence
    include Enumerable

    BATCH_SIZE = 100

    def initialize(user, before: Date.current, batch_size: BATCH_SIZE)
      @user = user
      @before = before
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
      @user.daily_responses.submitted.reviewed.where(date: ...@before).preload(:daily_exercise)
    end

    def day_for(response)
      results = ReviewedSectionResults.for(response, require_rubric: true, include_eased: true)
      day = Day.new(date: response.date, results: results, completion: completion_for(response), rungs: rungs_for(response))
      day if day.evidence?
    end

    def completion_for(response)
      keys = response.adaptation_section_keys
      assessed = response.assessed_adaptation_sections
      state = if keys.empty?
        :none
      elsif !response.completion_evidence?(sections: keys)
        :unknown
      else
        (keys - assessed).empty? ? :complete : :incomplete
      end
      ratings = assessed.to_h { |key| [ key, response.self_rating_for(key) ] }
      Completion.new(state: state, assigned: response.daily_exercise.planned_size, delivered: keys.size,
        answered: assessed.size, too_hard: ratings.select { |_, rating| ReviewedSectionResults.too_hard?(rating) }.keys,
        ratings_known: ratings.values.all?(&:present?))
    end

    def rungs_for(response)
      notes = response.daily_exercise.plan_notes
      map = notes["kind_rungs"] if notes.is_a?(Hash)
      return {} unless map.is_a?(Hash)

      map.select { |key, rung| ExerciseSection.keys.include?(key) && KindDifficulty::LEVELS.include?(rung) }
    end
  end
end
