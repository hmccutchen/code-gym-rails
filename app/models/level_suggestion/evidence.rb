class LevelSuggestion
  class Evidence
    # Bounds reads only; skipped and eased sections don't count, so a rare kind may never fill its own window.
    RESPONSE_WINDOW = 60

    attr_reader :results, :newest_date

    def self.for(user)
      responses = user.daily_responses.submitted.reviewed
                      .preload(:daily_exercise).order(date: :desc).limit(RESPONSE_WINDOW)
                      .select(&:reviewed?)
      new(responses)
    end

    def initialize(responses)
      @newest_date = responses.first&.date
      @results = responses.flat_map { |response| day_results(response) }.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    private

    def day_results(response)
      daily = response.daily_exercise&.daily_kinds.to_a.map(&:key)

      ReviewedSectionResults.for(response, require_rubric: true).map do |result|
        [ result.kind, Result.new(date: result.date, level: result.level, ai_rating: result.ai_rating,
                                  self_rating: result.self_rating, rotated: daily.exclude?(result.kind)) ]
      end
    end
  end
end
