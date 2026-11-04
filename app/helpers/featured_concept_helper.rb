module FeaturedConceptHelper
  # Memoized for the request: the callout and every section on the page read the same pick.
  def featured_concept
    return @featured_concept if defined?(@featured_concept)

    @featured_concept = current_user && FeaturedConcept.for(current_user)
  end

  def featured_section?(concept, bucket)
    featured_concept.present? && featured_concept.marks?(concept: concept, bucket: bucket)
  end

  def featured_callout_shown?(exercise, day_response)
    featured_concept.present? &&
      (exercise.nil? || day_response&.submitted? || exercise.concepts_withheld_before_submission.exclude?(featured_concept.concept))
  end

  # Learn reads today's set, or a paused user's held one, without carrying it forward as the dashboard does.
  def featured_shown_beside_todays_set?
    return false if featured_concept.blank?

    exercise = current_user.todays_or_held_exercise
    featured_callout_shown?(exercise, exercise&.daily_response)
  end

  # The tagline can describe what a section asks the engineer to find, so it waits until the day is submitted.
  def featured_tagline_shown?(day_response)
    day_response.nil? || day_response.submitted?
  end
end
