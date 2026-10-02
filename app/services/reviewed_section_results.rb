# The sections of one submitted, reviewed response that count as evidence of
# how the engineer did at a rung: answered, graded with a rating from the
# closed list, and stamped with the rung they were pitched at. Eased sections
# are left out unless a caller asks for them. Pure over the response it is
# given; callers choose which responses to load.
class ReviewedSectionResults
  # The lowest AI rating a co-favourable result can carry.
  FAVOURABLE_BAR = DailyResponse::AI_RATING_FAVORABLE.min_by { |rating| ConceptMastery::AI_RATING_RANK.fetch(rating) }

  Result = Data.define(:date, :kind, :level, :ai_rating, :self_rating, :eased) do
    def initialize(date:, kind:, level:, ai_rating:, self_rating:, eased: false)
      super
    end

    def at_or_above?(bar) = ReviewedSectionResults.at_or_above?(ai_rating, bar)
    def favourable?(bar:) = ReviewedSectionResults.favourable?(ai_rating, self_rating, bar: bar)
    def too_hard? = ReviewedSectionResults.too_hard?(self_rating)
  end

  # The rating rules as the competency gate and TrackGraduation read them,
  # TrackGraduation's own result type included. ConceptMastery and RungLedger
  # predate this class and still read the same rating lists directly.
  def self.at_or_above?(ai_rating, bar)
    rank = ConceptMastery::AI_RATING_RANK[ai_rating]
    rank.present? && rank >= ConceptMastery::AI_RATING_RANK.fetch(bar)
  end

  # The AI rating's level calibration is unverified, so a result is
  # favourable only when the engineer's own rating agrees.
  def self.favourable?(ai_rating, self_rating, bar:)
    at_or_above?(ai_rating, bar) && DailyResponse::SELF_RATING_FAVORABLE.include?(self_rating)
  end

  def self.too_hard?(self_rating) = DailyResponse::SELF_RATING_UNFAVORABLE.include?(self_rating)

  # Results come in registry order, so a rule that takes the latest n results
  # cuts a day at the same place every time.
  def self.for(response, require_rubric: false, include_eased: false)
    return [] unless response.submitted? && response.reviewed? && readable?(response)

    response.answered_sections.sort_by { |section| ExerciseSection.keys.index(section) }.filter_map do |section|
      data = response.daily_exercise.problem_set[section]
      review = response.ai_review[section]
      next unless counts?(data, review, require_rubric, include_eased)

      Result.new(date: response.date, kind: section, level: data["pitched_at"], ai_rating: review["rating"],
                 self_rating: self_rating(response, section), eased: data["eased"].present?)
    end
  end

  # Rows written by older code, or edited by hand, can hold any JSON. They are
  # skipped rather than raised on, since the competency gate reads them while
  # planning every day. Public because the gate's evidence loader reads other
  # fields of the same row and has to skip the same rows.
  def self.readable?(response)
    [ response.ai_review, response.answers, response.daily_exercise&.problem_set ].all?(Hash)
  end

  def self.counts?(data, review, require_rubric, include_eased)
    data.is_a?(Hash) && review.is_a?(Hash) && data["pitched_at"].present? && (include_eased || data["eased"].blank?) &&
      ConceptMastery::AI_RATING_RANK.key?(review["rating"]) &&
      (!require_rubric || review["rubric"] == AiService::RUBRIC_VERSION)
  end
  private_class_method :counts?

  def self.self_rating(response, section)
    response.section_ratings[section] if response.section_ratings.is_a?(Hash)
  end
  private_class_method :self_rating
end
