class LevelSuggestion
  class Evidence
    attr_reader :results, :newest_date

    def self.for(user, today: nil)
      Time.use_zone(user.effective_time_zone) do
        today ||= Date.current
        results = AdaptationHistory.each(user, on_or_after: today - LevelSuggestion::EVIDENCE_DAYS + 1,
          before: today + 1, require_rubric: true).flat_map do |response|
          ReviewedSectionResults.for(response, require_rubric: true)
        end
        new(results)
      end
    end

    def initialize(results)
      @newest_date = results.map(&:date).max
      @results = results.group_by(&:kind).transform_values { |entries| entries.sort_by(&:date).reverse.uniq(&:date).map { |result| track_result(result) } }
    end

    private

    def track_result(result)
      Result.new(date: result.date, level: result.level, ai_rating: result.ai_rating, self_rating: result.self_rating,
        concept: result.concept, bucket: result.bucket)
    end
  end
end
