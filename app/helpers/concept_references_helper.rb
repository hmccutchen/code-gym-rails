module ConceptReferencesHelper
  # Nil when no reference exists yet, which renders no dropdown; generation stays in GenerateConceptReferenceJob.
  def concept_reference_for(concept, bucket)
    return nil if concept.blank?

    # Memoized per request: one page repeats a concept across its sections and days.
    @concept_references ||= {}
    @concept_references.fetch([ concept, bucket ]) do |key|
      @concept_references[key] = current_user.concept_references.find_by(concept: concept, language: bucket)
    end
  end

  # The exposure index counts submitted responses only, so today's in-progress response never counts.
  def first_exposure?(concept, bucket, date)
    return false unless ConceptExposureIndex.counted?(concept)
    current_user.concept_exposures.count(concept, bucket, on_or_before: date).zero?
  end
end
