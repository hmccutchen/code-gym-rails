class ExerciseAdditionRequest
  Outcome = Data.define(:status, :addition)

  def self.call(**options) = new(**options).call
  def self.claim_key(exercise) = "exercise_addition/#{exercise.id}"

  def self.current?(user, exercise)
    Time.use_zone(user.effective_time_zone) do
      exercise.date == Date.current && user.todays_or_held_exercise&.id == exercise.id
    end
  end

  def self.with_locked(exercise)
    return unless exercise

    User.transaction do
      user = User.active.lock.find_by(id: exercise.user_id)
      current = user&.daily_exercises&.find_by(id: exercise.id)
      next unless current

      current.with_response_locked { |response| yield user, current, response }
    end
  end

  def self.recover!(exercise)
    result = :deleted
    held = AdvisoryLock.hold(claim_key(exercise)) do
      with_locked(exercise) { |_user, current, _response| result = recover_locked!(current) }
    end
    held ? result : :busy
  end

  def self.recover_locked!(exercise)
    addition = exercise.exercise_additions.active.lock.first
    return :unchanged unless addition&.expired?

    addition.expire!
    :recovered
  end

  def self.fail!(addition, claim:)
    with_locked(addition.daily_exercise) do |_user, exercise, _response|
      exercise.exercise_additions.lock.find_by(id: addition.id)&.fail_claim!(claim)
    end
  end

  def initialize(user:, exercise:, request_uuid:, kind:, draft_scope:, revision:, enqueue:)
    @enqueue = enqueue
    @user, @exercise, @uuid, @kind, @scope = user, exercise, request_uuid, kind, draft_scope
    @revision = Integer(revision.to_s, 10, exception: false)
  end

  def call
    return outcome(:not_current) unless @exercise.user_id == @user.id
    return outcome(:invalid) unless ExerciseAddition::UUID_FORMAT.match?(@uuid.to_s)

    result = outcome(:deleted)
    held = AdvisoryLock.hold(self.class.claim_key(@exercise)) { result = accept }
    return replay_while_busy || outcome(:busy) unless held

    ActiveRecord.after_all_transactions_commit { result = enqueue(result) } if result.status == :accepted
    result
  end

  private

  def accept
    self.class.with_locked(@exercise) do |user, exercise, response|
      refusal = identity_refusal(user, exercise)
      next outcome(refusal) if refusal
      prior = exercise.exercise_additions.lock.find_by(request_uuid: @uuid)
      next outcome(:replayed, prior) if prior

      self.class.recover_locked!(exercise)
      refusal = acceptance_refusal(user, exercise, response)
      next outcome(refusal) if refusal
      outcome(:accepted, exercise.exercise_additions.create!(request_uuid: @uuid, kind: @kind,
        draft_scope: @scope, date: exercise.date))
    end || outcome(:deleted)
  end

  def identity_refusal(user, exercise)
    return :stale unless exercise.draft_scope == @scope.to_s
    :not_current unless self.class.current?(user, exercise)
  end

  def acceptance_refusal(user, exercise, response)
    return :manifest_changed unless exercise.active_section_keys.size == @revision
    return :submitted if response&.submitted?
    return :busy if exercise.regenerating? || exercise.exercise_additions.active.exists?
    return :key_required unless user.provider_ready?
    :unavailable unless ExerciseAddition.available_kinds(user, exercise).any? { |kind| kind.key == @kind }
  end

  def replay_while_busy
    exercise = @user.daily_exercises.find_by(id: @exercise.id)
    return outcome(:not_current) unless exercise
    refusal = identity_refusal(@user, exercise)
    return outcome(refusal) if refusal

    prior = exercise.exercise_additions.find_by(request_uuid: @uuid)
    outcome(:replayed, prior) if prior
  end

  def enqueue(result)
    job = @enqueue.call(result.addition)
    raise "Addition was not enqueued" unless job

    result
  rescue StandardError => error
    Rails.logger.warn("[exercise_addition_enqueue] addition=#{result.addition.id} error=#{error.class}")
    self.class.with_locked(@exercise) do |_user, exercise, _response|
      exercise.exercise_additions.lock.find_by(id: result.addition.id)&.fail_queued!
    end
    outcome(:failed, result.addition)
  end

  def outcome(status, addition = nil) = Outcome.new(status: status, addition: addition)
end
