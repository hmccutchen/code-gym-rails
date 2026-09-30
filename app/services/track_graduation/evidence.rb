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
      @results = responses.flat_map { |response| results_in(response) }
                          .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    private

    def results_in(response)
      problem_set = response.daily_exercise.problem_set
      response.answered_sections.filter_map do |section|
        data = problem_set[section]
        rating = response.ai_rating_for(section)
        next unless data.is_a?(Hash) && data["pitched_at"].present? && !data["eased"] && rating

        [ section, Result.new(date: response.date, level: data["pitched_at"], ai_rating: rating,
                              self_rating: response.self_rating_for(section)) ]
      end
    end
  end
end
