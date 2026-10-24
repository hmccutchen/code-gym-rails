module ConceptReferencesHelper
  # Nil when no reference exists yet, which renders no dropdown; generation stays in GenerateConceptReferenceJob.
  def concept_reference_for(concept, language)
    return nil if concept.blank?

    # Memoized per request: history renders every section of ten days, which repeats concepts.
    @concept_references ||= {}
    @concept_references.fetch([ concept, language ]) do |key|
      @concept_references[key] = ConceptReference.find_by(concept: concept, language: language)
    end
  end

  # The exposure index counts submitted responses only, so today's in-progress response never counts.
  def first_exposure?(concept, bucket, date)
    return false if concept.blank? || concept == "other"
    current_user.concept_exposure_count(concept, bucket, on_or_before: date).zero?
  end
end
