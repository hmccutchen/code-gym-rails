# Design notes: docs/code-notes/app/jobs/generate_concept_reference_job.md
class GenerateConceptReferenceJob < ApplicationJob
  queue_as :provider_calls

  # One queued job per priority, so a click is never discarded for a bulk press; the claim stops the second call.
  limits_concurrency key: ->(args) { "#{priority || JobPriority::CLICK}/#{self.class.claim_key(**args.slice(:user_id, :language, :concept))}" },
                     to: 1, on_conflict: :discard,
                     duration: CallProfiles.call_budget_seconds(CallProfiles::CONCEPT_REFERENCE_READ_TIMEOUT).seconds

  def self.queue_missing(user, pairs, priority: JobPriority::CLICK)
    return unless user.writes_learn_content?

    ConceptReference.missing_for(user, pairs).each do |concept, language|
      set(priority: priority).perform_later(concept: concept, language: language, user_id: user.id)
    end
  end

  def self.queue_rewrites(user, pairs, priority: JobPriority::CLICK)
    seen = ConceptReference.seen_by(user, concept: pairs.map(&:first).uniq, language: pairs.map(&:last).uniq)
    pairs.each do |concept, language|
      set(priority: priority).perform_later(concept: concept, language: language, user_id: user.id, refresh: true,
                                            seen_version: seen[[ concept, language ]]&.generation_version || 0)
    end
  end

  def self.claim_key(user_id:, language:, concept:) = "concept_reference/#{user_id}/#{language}/#{concept}"

  # A rewrite asked for against an older seen_version already ran; jobs queued by older code pass no seen_version.
  def perform(concept:, language:, user_id:, refresh: false, seen_version: nil)
    return if concept == "other"

    user = User.active.find_by(id: user_id)
    return unless user&.writes_learn_content? && wanted?(ConceptReference.for(user, concept: concept, language: language), refresh, seen_version)

    claimed = AdvisoryLock.hold(self.class.claim_key(user_id: user.id, language: language, concept: concept)) do
      write_up(user, concept, language, refresh, seen_version)
    end
    Rails.logger.info("Skipped concept reference for #{concept}/#{language}: another job is writing it") unless claimed
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

  def wanted?(seen, refresh, seen_version)
    return false unless seen_version.nil? || seen_version == (seen&.generation_version || 0)

    seen.nil? || (refresh && !seen.fully_written?)
  end

  def write_up(user, concept, language, refresh, seen_version)
    seen = ConceptReference.uncached { ConceptReference.for(user, concept: concept, language: language) }
    return unless wanted?(seen, refresh, seen_version)

    reference = AiService.for(user).generate_concept_reference(user, concept, language)
    case write_own(user, concept, language, reference, refresh:, seen_version:)
    when :account_deleted then log_deleted(user.id, concept, language)
    when :skipped then Rails.logger.info("Skipped concept reference for #{concept}/#{language}: the row changed during the call")
    else
      ConceptReferenceFailures.clear(user_id: user.id, concept: concept, language: language)
      Rails.logger.info("Generated concept reference for #{concept}/#{language}")
    end
  end

  # The owner is share-locked first, as AccountDeletion locks it, so a deletion during the call leaves nothing behind.
  def write_own(user, concept, language, reference, refresh:, seen_version:)
    attributes = ConceptReference::WRITTEN_FIELDS.index_with { |field| reference[field] }

    User.transaction do
      next :account_deleted unless User.active.lock("FOR SHARE").exists?(id: user.id)

      own = ConceptReference.for(user, concept: concept, language: language)
      next rewrite(own, attributes, refresh, seen_version) if own

      ConceptReference.create!(attributes.merge("user_id" => user.id, "concept" => concept, "language" => language,
                                                "generation_version" => 1))
      :written
    end
  end

  def rewrite(own, attributes, refresh, seen_version)
    own.with_lock do
      next :skipped unless wanted?(own, refresh, seen_version)

      own.update!(attributes.merge(generation_version: own.generation_version + 1))
      :written
    end
  end

  def log_deleted(user_id, concept, language)
    Rails.logger.info("Stopped concept reference #{concept}/#{language} for user #{user_id}: the account was deleted")
  end
end
