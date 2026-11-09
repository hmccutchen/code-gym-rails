module PracticePolicyMode
  INITIATE_PRACTICE_POLICY = false

  def self.display_status(user)
    active?(user) ? :active : :inactive
  rescue ArgumentError => error
    Rails.logger.warn("[practice_display] user_id=#{user.id} error=#{error.class.name}")
    :unavailable
  end

  # Writers call this under the user lock; no enrollment result survives a provider call.
  def self.active?(user, initiate: INITIATE_PRACTICE_POLICY)
    ActiveRecord::Base.uncached do
      enrolled = false
      user.daily_responses.where.not(mastery_application: {}).select(:id, :mastery_application).find_each do |response|
        receipt = DailyResponse.decode_mastery_application(response.mastery_application)
        enrolled = true if receipt["policy"] == 2
      end
      scope = user.concept_masteries
      scope.reconciling.or(scope.where.not(practice_requests: {})).select(:id, :review_reconciliation, :practice_requests).find_each do |row|
        journal = ConceptMastery::Reconciliation.decode(row.review_reconciliation)
        requests = ConceptMastery::Reconciliation.validate_requests!(row.practice_requests)
        enrolled = true if journal["version"] == 2 || requests.any?
      end
      user.daily_exercises.where("plan_notes ? 'practice_schedule'").select(:id, :plan_notes).find_each do |exercise|
        note = PracticeSchedule::Note.decode(exercise.plan_notes.fetch("practice_schedule"))
        enrolled = true if note.any?
      end
      initiate || enrolled
    end
  end
end
