# Whether a graded review's rating agrees with the gaps it calls essential,
# under AiService::RATING_RUBRIC: solid and strong list none, beginner and
# developing list at least one. Log-only — nothing rewrites a rating from this —
# so its job is to measure how often the grader follows the rubric. Pure.
class RubricCheck
  GAP_FREE_RATINGS = DailyResponse::AI_RATING_FAVORABLE
  GAPPED_RATINGS   = DailyResponse::AI_RATING_UNFAVORABLE

  def initialize(review)
    @rating = review["rating"]
    @missed = DailyResponse.review_points(review["missed"])
    @raw    = review["essential_gaps"]
  end

  # Sorted, distinct positions in "missed", or nil when the grader's list
  # cannot be read as positions in this review's missed list.
  def essential_gaps
    return @essential_gaps if defined?(@essential_gaps)

    @essential_gaps = readable_gaps? ? @raw.uniq.sort : nil
  end

  # true or false when it can be checked, nil when it cannot.
  def agrees?
    return if essential_gaps.nil?

    if GAP_FREE_RATINGS.include?(@rating)
      essential_gaps.empty?
    elsif GAPPED_RATINGS.include?(@rating)
      essential_gaps.any?
    end
  end

  def missed_count = @missed.size

  private

  def readable_gaps?
    @raw.is_a?(Array) && @raw.all? { |position| position.is_a?(Integer) && position.between?(0, @missed.size - 1) }
  end
end
