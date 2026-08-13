class GenerateConceptReferenceJob < ApplicationJob
  queue_as :default

  # Best-effort: any failure is logged and swallowed, so a missing reference
  # renders as nothing and is retried the next time anyone submits the concept.
  def perform(concept:, language:, user_id:)
    # "other" is the off-vocabulary catch-all from ProblemSetIngest#normalize_concepts!,
    # not a real concept worth a reference.
    return if concept == "other"

    # Another job may have generated it in the enqueue/run gap.
    return if ConceptReference.exists?(concept: concept, language: language)

    user = User.find_by(id: user_id)
    return unless user

    reference = AiService.for(user).generate_concept_reference(user, concept, language)

    ConceptReference.create!(
      concept:      concept,
      language:     language,
      tagline:      reference["tagline"],
      explanation:  reference["explanation"],
      code_example: reference["code_example"],
      senior_lens:  reference["senior_lens"]
    )

    Rails.logger.info("Generated concept reference for #{concept}/#{language}")
  rescue ActiveRecord::RecordNotUnique
    # A concurrent job won the race; nothing to do.
    Rails.logger.info("Skipped duplicate concept reference for #{concept}/#{language}")
  rescue AiService::Error => e
    Rails.logger.warn("Failed to generate concept reference for #{concept}/#{language}: #{e.message}")
  end
end
