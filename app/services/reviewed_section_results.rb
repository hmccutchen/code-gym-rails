# The sections of one submitted, reviewed response that count as evidence of
# how the engineer did at a rung: answered, graded with a rating from the
# closed list, stamped with the rung they were pitched at, and not eased.
# Pure over the response it is given; callers choose which responses to load.
class ReviewedSectionResults
  # The AI rating is provider output; one outside the closed list is not a
  # judgment any rule can read.
  RATINGS = (DailyResponse::AI_RATING_FAVORABLE + DailyResponse::AI_RATING_UNFAVORABLE).freeze

  Result = Data.define(:date, :kind, :level, :ai_rating, :self_rating)

  # Results come in registry order, so a rule that takes the latest n results
  # cuts a day at the same place every time.
  def self.for(response, require_rubric: false)
    return [] unless response.submitted? && response.reviewed?

    problem_set = response.daily_exercise.problem_set
    response.answered_sections.sort_by { |section| ExerciseSection.keys.index(section) }.filter_map do |section|
      data = problem_set[section]
      next unless counts?(response, section, data, require_rubric)

      Result.new(date: response.date, kind: section, level: data["pitched_at"],
                 ai_rating: response.ai_rating_for(section), self_rating: response.self_rating_for(section))
    end
  end

  def self.counts?(response, section, data, require_rubric)
    data.is_a?(Hash) && data["pitched_at"].present? && !data["eased"] &&
      RATINGS.include?(response.ai_rating_for(section)) &&
      (!require_rubric || response.ai_review.dig(section, "rubric") == AiService::RUBRIC_VERSION)
  end
  private_class_method :counts?
end
