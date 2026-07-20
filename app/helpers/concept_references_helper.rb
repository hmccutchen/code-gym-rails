module ConceptReferencesHelper
  # The cached durable reference for a section's concept in the given language,
  # or nil. Concepts with no generated reference yet — "other", and first-ever
  # exposures whose lazy background generation hasn't run — simply render no
  # dropdown. Display only; generation stays in GenerateConceptReferenceJob.
  def concept_reference_for(concept, language)
    return nil if concept.blank?
    ConceptReference.find_by(concept: concept, language: language)
  end
end
