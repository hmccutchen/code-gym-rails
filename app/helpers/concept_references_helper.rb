module ConceptReferencesHelper
  # Nil when no reference exists yet, which renders no dropdown; generation stays in GenerateConceptReferenceJob.
  def concept_reference_for(concept, language)
    return nil if concept.blank?
    ConceptReference.find_by(concept: concept, language: language)
  end

  # The exposure index counts submitted responses only, so today's in-progress response never counts.
  def first_exposure?(concept, bucket, date)
    return false if concept.blank? || concept == "other"
    current_user.concept_exposure_count(concept, bucket, on_or_before: date).zero?
  end
end
