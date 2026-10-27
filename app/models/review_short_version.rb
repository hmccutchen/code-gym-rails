# Design notes: docs/code-notes/app/models/review_short_version.md
class ReviewShortVersion
  def initialize(response, exposures:)
    @response  = response
    @exposures = exposures
  end

  def offered?(section)
    section = section.to_s
    qualifies?(section) && earlier_sections(section).none? { |other| tag(other) == tag(section) && qualifies?(other) }
  end

  def essential_gap?(section)
    return false if @response.ai_rating_for(section).blank?

    @response.ai_rating_unfavorable?(section) || graded_gaps(section).present?
  end

  private

  def qualifies?(section)
    return false unless @response.section_reviewed?(section)

    count = @exposures.count_for(section, tag(section), @response.daily_exercise.language, on_or_before: @response.date)
    return false if count.nil?

    count == 1 || @response.ai_rating_unfavorable?(section)
  end

  def graded_gaps(section)
    graded = ReviewProseVerdict.as_graded(@response.ai_review&.dig(section.to_s))
    RubricCheck.new(graded).essential_gaps if graded
  end

  def earlier_sections(section) = @response.section_keys.take_while { |key| key != section }

  def tag(section) = @response.concept_tags[section]
end
