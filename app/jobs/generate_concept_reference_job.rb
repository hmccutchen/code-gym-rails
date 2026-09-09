class GenerateConceptReferenceJob < ApplicationJob
  queue_as :default

  # Best-effort: any failure is logged and swallowed, so a missing reference
  # renders as nothing and is retried the next time anyone submits the concept.
  #
  # `refresh_guide` is what the Learn tab passes to regenerate a row that
  # predates guides. It defaults to false so the first-exposure caller in
  # ResponsesController keeps its original contract: any existing row is a
  # no-op there, whatever it does or doesn't carry.
  #
  # A legacy row is rewritten WHOLE, reference text included, because both
  # halves have to come from one response for them to be consistent by
  # construction. That is why the Learn tab only ever asks for it on a concept
  # someone deliberately opened, never in bulk.
  def perform(concept:, language:, user_id:, refresh_guide: false)
    # "other" is the off-vocabulary catch-all from ProblemSetIngest#normalize_concepts!,
    # not a real concept worth a reference.
    return if concept == "other"

    # Another job may have generated it in the enqueue/run gap.
    existing = ConceptReference.find_by(concept: concept, language: language)
    return if existing && (existing.guide? || !refresh_guide)

    user = User.find_by(id: user_id)
    return unless user

    reference = AiService.for(user).generate_concept_reference(user, concept, language)
    attributes = (AiService::CONCEPT_REFERENCE_FIELDS + AiService::CONCEPT_GUIDE_FIELDS)
                   .index_with { |field| reference[field] }

    if existing
      existing.update!(attributes)
    else
      ConceptReference.create!(attributes.merge("concept" => concept, "language" => language))
    end

    Rails.logger.info("Generated concept reference for #{concept}/#{language}")
  rescue ActiveRecord::RecordNotUnique
    # A concurrent job won the race; nothing to do.
    Rails.logger.info("Skipped duplicate concept reference for #{concept}/#{language}")
  rescue AiService::Error => e
    Rails.logger.warn("Failed to generate concept reference for #{concept}/#{language}: #{e.message}")
  end
end
