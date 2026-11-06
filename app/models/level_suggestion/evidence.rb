class LevelSuggestion
  class Evidence
    # Qualifying response days across all kinds, before each kind's rung and cutoff filters.
    RESPONSE_WINDOW = 60

    attr_reader :results, :newest_date

    def self.for(user)
      results = AdaptationHistory.recent(user, limit: RESPONSE_WINDOW) do |response|
        ReviewedSectionResults.for(response, require_rubric: true)
      end
      new(results.flatten)
    end

    def initialize(results)
      @newest_date = results.first&.date
      @results = results.group_by(&:kind).transform_values { |entries| entries.map { |result| track_result(result) } }
    end

    private

    def track_result(result)
      Result.new(date: result.date, level: result.level, ai_rating: result.ai_rating, self_rating: result.self_rating)
    end
  end
end
