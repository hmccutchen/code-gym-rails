class GenerateAdditionalExerciseJob < ApplicationJob
  queue_as :provider_calls
  queue_with_priority JobPriority::CLICK

  def perform(addition_id:)
    addition = ExerciseAddition.includes(daily_exercise: :user).find_by(id: addition_id)
    return unless addition && addition.daily_exercise.user.anonymized_at.nil?

    user = addition.daily_exercise.user
    Time.use_zone(user.effective_time_zone) do
      unless_account_deleted(user) do
        AdvisoryLock.hold(ExerciseAdditionRequest.claim_key(addition.daily_exercise)) { execute(addition) }
      end
    end
  end

  private

  def execute(addition)
    claimed = claim(addition)
    return unless claimed

    user, addition, token = claimed
    key_used = user.key_in_use
    context = PracticeGeneration.capture_addition(user, addition: addition, claim: token)
    return ExerciseAdditionRequest.fail!(addition, claim: token) unless context

    generate(user, addition, token, context)
  rescue ProviderError::AllSectionsRejectedError
    ExerciseAdditionRequest.fail!(addition, claim: token) if token
  rescue ProviderError, SetupError => error
    if token
      ExerciseAdditionRequest.fail!(addition, claim: token) do |fresh|
        fresh.report_call_failure(key_used) { fresh.record_generation_failure!(error, counts_toward_key_hold: false) }
      end
    end
    Rails.logger.warn("[exercise_addition_failed] addition=#{addition.id} error=#{error.class}")
  rescue StandardError
    ExerciseAdditionRequest.fail!(addition, claim: token) if token
    raise
  end

  def claim(addition)
    ExerciseAdditionRequest.with_locked(addition.daily_exercise) do |user, exercise, _response|
      current = exercise.exercise_additions.lock.find_by(id: addition.id)
      current&.expire!
      token = current&.claim_once!
      [ user, current, token ] if token
    end
  end

  def generate(user, addition, token, context)
    service = AiService.for(user)
    deadline = GenerationDeadline.new(token + DailyExercise::REGENERATION_DEADLINE)
    judged = service.generate_judged_exercise(user, language: addition.daily_exercise.language,
      deadline: deadline, schedule_context: context)
    result = PracticeGeneration.commit_append(user, addition: addition, claim: token,
      context: context, judged: judged, drafted_by: service)
    ExerciseAdditionRequest.fail!(addition, claim: token) unless result.status == :saved
  end
end
