module FeaturedConceptHelper
  # The tagline can describe what a section asks the engineer to find, so it waits until the day is submitted.
  def featured_tagline_shown?(day_response)
    day_response.nil? || day_response.submitted?
  end
end
