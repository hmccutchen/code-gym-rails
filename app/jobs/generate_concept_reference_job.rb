# Design notes: docs/code-notes/app/jobs/generate_concept_reference_job.md
class GenerateConceptReferenceJob < ApplicationJob
  queue_as :provider_calls

  limits_concurrency key: ->(args) { "#{args.fetch(:user_id)}/#{args.fetch(:language)}/#{args.fetch(:concept)}" },
                     to: 1, on_conflict: :discard,
                     duration: CallProfiles.call_budget_seconds(CallProfiles::CONCEPT_REFERENCE_READ_TIMEOUT).seconds

  def self.queue_missing(user, pairs, priority: JobPriority::CLICK)
    return unless user.writes_learn_content?

    ConceptReference.missing_for(user, pairs).each do |concept, language|
      set(priority: priority).perform_later(concept: concept, language: language, user_id: user.id)
    end
  end

  # refresh rewrites the whole row so its parts come from one response; only a deliberate Learn click passes it.
  def perform(concept:, language:, user_id:, refresh: false)
    return if concept == "other"

    user = User.active.find_by(id: user_id)
    return unless user&.writes_learn_content?

    seen = ConceptReference.for(user, concept: concept, language: language)
    return if seen && (seen.fully_written? || !refresh)

    reference = AiService.for(user).generate_concept_reference(user, concept, language)
    case write_own(user, concept, language, reference, seen)
    when :account_deleted then log_deleted(user_id, concept, language)
    when :skipped then Rails.logger.info("Skipped concept reference for #{concept}/#{language}: already fully written")
    else
      ConceptReferenceFailures.clear(user_id: user_id, concept: concept, language: language)
      Rails.logger.info("Generated concept reference for #{concept}/#{language}")
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # The validation can see a concurrent job's committed row before the index does, so both errors mean it won.
    raise if e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors[:concept].blank?

    Rails.logger.info("Skipped duplicate concept reference for #{concept}/#{language}")
  rescue ProviderError => e
    e.provider ||= user&.provider
    ConceptReferenceFailures.record(user_id: user_id, concept: concept, language: language, error: e)
    Rails.logger.warn("Failed to generate concept reference for #{concept}/#{language} (#{ProviderFailure.classify(e)}): #{e.message}")
  rescue SetupError => e
    ConceptReferenceFailures.record(user_id: user_id, concept: concept, language: language, error: e)
    Rails.logger.error("Setup error generating concept reference #{concept}/#{language} for user #{user_id}: #{e.message}")
  end

  private

  # The owner is share-locked first, as AccountDeletion locks it, so a deletion during the call leaves nothing behind.
  def write_own(user, concept, language, reference, seen)
    attributes = ConceptReference::WRITTEN_FIELDS.index_with { |field| reference[field] }

    User.transaction do
      next :account_deleted unless User.active.lock("FOR SHARE").exists?(id: user.id)

      own = ConceptReference.find_by(user_id: user.id, concept: concept, language: language)
      next rewrite(own, attributes) if own

      ConceptReference.create!(attributes.merge("user_id" => user.id, "concept" => concept, "language" => language,
                                                "generation_version" => (seen&.generation_version || 0) + 1))
      :written
    end
  end

  # An expired permit or a direct perform_now bypasses queue concurrency control, so keep the lock.
  def rewrite(own, attributes)
    own.with_lock do
      next :skipped if own.fully_written?

      own.update!(attributes.merge(generation_version: own.generation_version + 1))
      :written
    end
  end

  def log_deleted(user_id, concept, language)
    Rails.logger.info("Stopped concept reference #{concept}/#{language} for user #{user_id}: the account was deleted")
  end
end
