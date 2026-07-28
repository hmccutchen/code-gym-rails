module ConceptReferencesHelper
  # The cached durable reference for a section's concept in the given language,
  # or nil. Concepts with no generated reference yet — "other", and first-ever
  # exposures whose lazy background generation hasn't run — simply render no
  # dropdown. Display only; generation stays in GenerateConceptReferenceJob.
  def concept_reference_for(concept, language)
    return nil if concept.blank?
    ConceptReference.find_by(concept: concept, language: language)
  end

  # True when the current user has never been exposed to this concept, in this
  # bucket, on or before the given date — today's own in-progress response is
  # never counted, since the exposure index only includes submitted responses
  # — i.e. this render would be their first-ever encounter. Reuses
  # User#concept_exposure_count (the same counter that gates improved_code)
  # rather than a second counter. Blank/"other" concepts never resolve to a
  # cached ConceptReference, but are guarded here too for consistency with
  # DailyResponse#improved_code_visible?.
  def first_exposure?(concept, bucket, date)
    return false if concept.blank? || concept == "other"
    current_user.concept_exposure_count(concept, bucket, on_or_before: date).zero?
  end
end
