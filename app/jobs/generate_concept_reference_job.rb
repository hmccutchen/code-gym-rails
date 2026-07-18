class GenerateConceptReferenceJob < ApplicationJob
  queue_as :default

  # Lazily generate the one-time cached reference for a single concept, using
  # the triggering user's API key. Enqueued from ResponsesController#create on
  # submission, once per concept lacking a reference. Best-effort: any failure
  # is logged and swallowed so a missing reference simply renders as nothing
  # and gets retried the next time anyone submits that concept.
  def perform(concept:, language:, user_id:)
    # Re-check after the enqueue/run gap — another user may have generated it.
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
    # Lost the race against a concurrent job for the same concept/language.
    # The other one won; nothing to do.
    Rails.logger.info("Skipped duplicate concept reference for #{concept}/#{language}")
  rescue AiService::Error => e
    # Best-effort: bad key, rate limit, invalid JSON. Don't surface to the user.
    Rails.logger.warn("Failed to generate concept reference for #{concept}/#{language}: #{e.message}")
  end
end
