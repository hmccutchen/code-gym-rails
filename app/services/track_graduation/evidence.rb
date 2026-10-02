class TrackGraduation
  class Evidence
    # Bounds history reads, not the results available to a rare kind: skipped
    # and eased sections do not count, so a rare kind can still need the led path.
    RESPONSE_WINDOW = 60

    attr_reader :results, :newest_date

    def self.for(user)
      responses = user.daily_responses.submitted.where.not(ai_review: [ nil, {} ])
                      .preload(:daily_exercise).order(date: :desc).limit(RESPONSE_WINDOW)
                      .select(&:reviewed?)
      new(responses)
    end

    def initialize(responses)
      @newest_date = responses.first&.date
      @results = responses.flat_map { |response| ReviewedSectionResults.for(response) }
                          .group_by(&:kind).transform_values { |results| results.map { |result| track_result(result) } }
    end

    private

    def track_result(result)
      Result.new(date: result.date, level: result.level, ai_rating: result.ai_rating, self_rating: result.self_rating)
    end
  end
end
