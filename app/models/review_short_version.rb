# Design notes: docs/code-notes/app/models/review_short_version.md
class ReviewShortVersion
  def initialize(response, exposures:)
    @response  = response
    @exposures = exposures
  end

  def key(section) = ConceptExposureIndex.key_for(section, @response.concept_tags[section.to_s], @response.daily_exercise.language)

  def offered?(section)
    section = section.to_s
    qualifies?(section) && earlier_sections(section).none? { |other| key(other) == key(section) && qualifies?(other) }
  end

  def pitfalls?(section)
    @response.section_keys.any? { |other| key(other) == key(section) && essential_gap?(other) }
  end

  def essential_gap?(section)
    return false if @response.ai_rating_for(section).blank?

    @response.ai_rating_unfavorable?(section) || graded_gaps(section).present?
  end

  private

  def qualifies?(section)
    return false unless @response.section_reviewed?(section) && key(section)

    count = @exposures.count(*key(section), on_or_before: @response.date)
    count == 1 || @response.ai_rating_unfavorable?(section)
  end

  def graded_gaps(section)
    graded = ReviewProseVerdict.as_graded(@response.ai_review&.dig(section.to_s))
    RubricCheck.new(graded).essential_gaps if graded
  end

  def earlier_sections(section) = @response.section_keys.take_while { |other| other != section }
end
