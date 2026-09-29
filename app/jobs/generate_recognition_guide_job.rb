class GenerateRecognitionGuideJob < ApplicationJob
  queue_as :default

  # Same permit as GenerateConceptReferenceJob, for the same reason: the row is
  # shared, so an overlapping job is discarded rather than billed twice.
  limits_concurrency key: ->(args) { "recognition_guide/#{args.fetch(:group_key)}" },
                     to: 1, on_conflict: :discard,
                     duration: AiService.call_budget_seconds(AiService::CONCEPT_REFERENCE_READ_TIMEOUT).seconds

  # Best-effort: any failure is logged and swallowed, and the next backfill
  # from the Learn tab tries again. A written guide is never rewritten.
  def perform(group_key:, user_id:)
    return unless RecognitionGuide::GROUP_KEYS.include?(group_key)
    return if RecognitionGuide.exists?(group_key: group_key)

    user = User.find_by(id: user_id)
    return unless user

    # ApiUsage dates the call with Date.current, which must be the user's day.
    guide = Time.use_zone(user.effective_time_zone) { AiService.for(user).generate_recognition_guide(user, group_key) }
    RecognitionGuide.create!(guide.merge("group_key" => group_key))

    Rails.logger.info("Generated recognition guide for #{group_key}")
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # Uniqueness is enforced twice, as in GenerateConceptReferenceJob: the
    # validation can see a concurrent job's committed row before the index does.
    raise if e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors[:group_key].blank?

    Rails.logger.info("Skipped duplicate recognition guide for #{group_key}")
  rescue AiService::Error => e
    Rails.logger.warn("Failed to generate recognition guide for #{group_key}: #{e.message}")
  end
end
