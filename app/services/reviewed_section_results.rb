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

  # ConceptMastery and RungLedger predate these rules and still read the rating lists directly.
  def self.at_or_above?(ai_rating, bar)
    rank = ConceptMastery::AI_RATING_RANK[ai_rating]
    rank.present? && rank >= ConceptMastery::AI_RATING_RANK.fetch(bar)
  end

  # The AI rating's calibration is unverified, so the engineer's own rating must agree.
  def self.favourable?(ai_rating, self_rating, bar:)
    at_or_above?(ai_rating, bar) && DailyResponse::SELF_RATING_FAVORABLE.include?(self_rating)
  end

  def self.too_hard?(self_rating) = DailyResponse::SELF_RATING_UNFAVORABLE.include?(self_rating)

  # Registry order, so a rule taking the latest n results cuts a day at the same place every time.
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

  # Skips malformed rows instead of raising, since the gate reads them on every plan; public for the gate's loader.
  def self.readable?(response)
    [ response.ai_review, response.answers, response.daily_exercise&.problem_set ].all?(Hash)
  end

  def self.counts?(data, review, require_rubric, include_eased)
    data.is_a?(Hash) && review.is_a?(Hash) && KindDifficulty::LEVELS.include?(data["pitched_at"]) &&
      (include_eased || data["eased"].blank?) &&
      ConceptMastery::AI_RATING_RANK.key?(review["rating"]) &&
      (!require_rubric || review["rubric"] == AiService::RUBRIC_VERSION)
  end
  private_class_method :counts?

  def self.self_rating(response, section)
    response.section_ratings[section] if response.section_ratings.is_a?(Hash)
  end
  private_class_method :self_rating
end
