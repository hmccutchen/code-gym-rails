class GenerateConceptReferenceJob < ApplicationJob
  queue_as :default

  # Discards overlaps so an incomplete result can't trigger another billed attempt on the shared row.
  limits_concurrency key: ->(args) { "#{args.fetch(:language)}/#{args.fetch(:concept)}" },
                     to: 1, on_conflict: :discard,
                     duration: AiService.call_budget_seconds(AiService::CONCEPT_REFERENCE_READ_TIMEOUT).seconds

  # refresh rewrites the whole row so its parts come from one response; only a deliberate Learn click passes it.
  def perform(concept:, language:, user_id:, refresh: false)
    # "other" is ProblemSetIngest's off-vocabulary catch-all, not a real concept.
    return if concept == "other"

    # Another job may have generated it in the enqueue/run gap.
    existing = ConceptReference.find_by(concept: concept, language: language)
    return if existing && (existing.fully_written? || !refresh)

    user = User.find_by(id: user_id)
    return unless user

    reference = AiService.for(user).generate_concept_reference(user, concept, language)
    attributes = (AiService::CONCEPT_REFERENCE_FIELDS + AiService::CONCEPT_GUIDE_FIELDS + AiService::CONCEPT_LADDER_FIELDS + [ "lesson" ])
                   .index_with { |field| reference[field] }

    if existing
      # An expired permit or a direct perform_now bypasses queue concurrency control, so keep the lock.
      existing.with_lock do
        next if existing.fully_written?

        existing.update!(attributes.merge(generation_version: existing.generation_version + 1))
      end
    else
      ConceptReference.create!(attributes.merge("concept" => concept, "language" => language, "generation_version" => 1))
    end

    ConceptReferenceFailures.clear(user_id: user_id, concept: concept, language: language)
    Rails.logger.info("Generated concept reference for #{concept}/#{language}")
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # The validation can see a concurrent job's committed row before the index does, so both errors mean it won.
    raise if e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors[:concept].blank?

    Rails.logger.info("Skipped duplicate concept reference for #{concept}/#{language}")
  rescue AiService::Error => e
    # Noted per user because the row is shared; an error raised after the call has no provider stamp of its own.
    e.provider ||= user&.provider
    ConceptReferenceFailures.record(user_id: user_id, concept: concept, language: language, error: e)
    Rails.logger.warn("Failed to generate concept reference for #{concept}/#{language} (#{ProviderFailure.classify(e)}): #{e.message}")
  end
end
