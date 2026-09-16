class GenerateConceptReferenceJob < ApplicationJob
  queue_as :default

  # The cache is shared across users and refresh modes. Discard overlaps so an
  # incomplete result cannot immediately trigger another queued, billed attempt.
  limits_concurrency key: ->(args) { "#{args.fetch(:language)}/#{args.fetch(:concept)}" },
                     to: 1, on_conflict: :discard,
                     duration: AiService.call_budget_seconds(AiService::CONCEPT_REFERENCE_READ_TIMEOUT).seconds

  # Best-effort: any failure is logged and swallowed, so a missing reference
  # renders as nothing and is retried the next time anyone submits the concept.
  #
  # `refresh` is what the Learn tab passes to rewrite a row missing its guide or
  # its ladder. It defaults to false so the first-exposure caller in
  # ResponsesController keeps its original contract: any existing row is a
  # no-op there, whatever it does or doesn't carry.
  #
  # A row is rewritten WHOLE, reference text included, because every part has
  # to come from one response to be consistent by construction. That is why
  # only a deliberate click asks for it.
  def perform(concept:, language:, user_id:, refresh: false)
    # "other" is the off-vocabulary catch-all from ProblemSetIngest#normalize_concepts!,
    # not a real concept worth a reference.
    return if concept == "other"

    # Another job may have generated it in the enqueue/run gap.
    existing = ConceptReference.find_by(concept: concept, language: language)
    return if existing && (existing.complete? || !refresh)

    user = User.find_by(id: user_id)
    return unless user

    reference = AiService.for(user).generate_concept_reference(user, concept, language)
    attributes = (AiService::CONCEPT_REFERENCE_FIELDS + AiService::CONCEPT_GUIDE_FIELDS + AiService::CONCEPT_LADDER_FIELDS)
                   .index_with { |field| reference[field] }

    if existing
      # Keep the write guard even with queue concurrency control: an expired
      # permit or a direct perform_now caller can bypass that control.
      existing.with_lock do
        next if existing.complete?

        existing.update!(attributes.merge(generation_version: existing.generation_version + 1))
      end
    else
      ConceptReference.create!(attributes.merge("concept" => concept, "language" => language, "generation_version" => 1))
    end

    Rails.logger.info("Generated concept reference for #{concept}/#{language}")
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # Uniqueness is enforced twice here, the same as User#resume_generation!'s
    # date race: the model validation's SELECT can see the other job's
    # already-committed row and raise RecordInvalid before the database
    # constraint ever gets a chance to raise RecordNotUnique. With 74-118 jobs
    # racing over 3 worker threads, the validation losing that race is the
    # common case, not the rare one, so both exceptions mean the same thing —
    # a concurrent job won.
    raise if e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors[:concept].blank?

    Rails.logger.info("Skipped duplicate concept reference for #{concept}/#{language}")
  rescue AiService::Error => e
    Rails.logger.warn("Failed to generate concept reference for #{concept}/#{language}: #{e.message}")
  end
end
