module FeaturedConceptHelper
  # Memoized for the request: the callout and every section on the page read the same pick.
  def featured_concept
    return @featured_concept if defined?(@featured_concept)

    @featured_concept = current_user && FeaturedConcept.for(current_user)
  end

  def featured_section?(concept, bucket)
    featured_concept.present? && featured_concept.marks?(concept: concept, bucket: bucket)
  end

  # The tagline can describe what a section asks the engineer to find, so it waits until the day is submitted.
  def featured_tagline_shown?(day_response)
    day_response.nil? || day_response.submitted?
  end
end
