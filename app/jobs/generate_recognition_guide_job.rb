# Design notes: docs/code-notes/app/jobs/generate_recognition_guide_job.md
class GenerateRecognitionGuideJob < ApplicationJob
  queue_as :provider_calls

  limits_concurrency key: ->(args) { "recognition_guide/#{args.fetch(:user_id)}/#{args.fetch(:group_key)}" },
                     to: 1, on_conflict: :discard,
                     duration: CallProfiles.call_budget_seconds(CallProfiles::CONCEPT_REFERENCE_READ_TIMEOUT).seconds

  # Best-effort: failures are logged and the next Learn backfill retries; a written guide is never rewritten.
  def perform(group_key:, user_id:)
    return unless RecognitionGuide::GROUP_KEYS.include?(group_key)

    user = User.active.find_by(id: user_id)
    return unless user&.writes_learn_content?
    return if RecognitionGuide.written_for?(user, group_key)

    # ApiUsage dates the call with Date.current, which must be the user's day.
    guide = Time.use_zone(user.effective_time_zone) { AiService.for(user).generate_recognition_guide(user, group_key) }
    if write_own(user, group_key, guide)
      Rails.logger.info("Generated recognition guide for #{group_key}")
    else
      Rails.logger.info("Stopped recognition guide #{group_key} for user #{user_id}: the account was deleted")
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # The validation can see a concurrent job's committed row before the unique index does.
    raise if e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors[:group_key].blank?

    Rails.logger.info("Skipped duplicate recognition guide for #{group_key}")
  rescue ProviderError => e
    Rails.logger.warn("Failed to generate recognition guide for #{group_key}: #{e.message}")
  rescue SetupError => e
    Rails.logger.error("Setup error generating recognition guide #{group_key} for user #{user_id}: #{e.message}")
  end

  private

  def write_own(user, group_key, guide)
    User.transaction do
      next false unless User.active.lock("FOR SHARE").exists?(id: user.id)

      RecognitionGuide.create!(guide.slice(*RecognitionGuide::FIELDS).merge("group_key" => group_key, "user_id" => user.id))
      true
    end
  end
end
