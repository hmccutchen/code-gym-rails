# Design notes: docs/code-notes/app/models/learner_extraction.md
module LearnerExtraction
  KEY = "learner_extraction".freeze
  MAX_ATTEMPTS = 2
  MAX_REPLY_ATTEMPTS = 2

  Ledger = Data.define(:attempts, :closed_at, :reply_attempts, :forgotten_at) do
    def self.from(plan_notes)
      stored = plan_notes.is_a?(Hash) ? plan_notes[KEY] : nil
      stored = {} unless stored.is_a?(Hash)
      new(attempts: stored["attempts"].to_i, closed_at: stored["closed_at"], reply_attempts: stored["reply_attempts"].to_i,
          forgotten_at: stored["forgotten_at"])
    end

    def closed? = closed_at.present?

    def to_h
      { "attempts" => attempts, "closed_at" => closed_at, "reply_attempts" => reply_attempts, "forgotten_at" => forgotten_at }.compact
    end
  end

  def self.for(exercise) = Ledger.from(exercise.plan_notes)

  # Returns true when the attempt was counted, false when the set is closed or spent, or :gone or :replaced.
  def self.count_attempt!(exercise, close:, response_id:)
    change(exercise, response_id: response_id) do |ledger|
      next false if ledger.closed? || ledger.attempts >= MAX_ATTEMPTS

      [ true, ledger.with(attempts: ledger.attempts + 1, closed_at: (Time.current.iso8601 if close)) ]
    end
  end

  def self.close!(exercise, response_id:)
    change(exercise, response_id: response_id) do |ledger|
      next :closed if ledger.closed?

      [ :closed, ledger.with(closed_at: Time.current.iso8601) ]
    end
  end

  # Yields whether both reply attempts are spent; the block returns the claim's token, or a symbol for why it took none.
  def self.count_reply_attempt!(exercise)
    change(exercise) do |ledger|
      token = yield ledger.reply_attempts >= MAX_REPLY_ATTEMPTS
      next token if token.is_a?(Symbol)

      [ token, ledger.with(reply_attempts: ledger.reply_attempts + 1) ]
    end
  end

  # The caller holds the user row lock, so an extraction's merge sees the stamp before it writes.
  def self.forget_all!(user)
    DailyExercise.where(user_id: user.id).where("jsonb_typeof(plan_notes) = 'object'").update_all([ <<~SQL.squish, { key: KEY, at: Time.current.iso8601 } ])
      plan_notes = jsonb_set(plan_notes, ARRAY[:key],
        (CASE WHEN jsonb_typeof(plan_notes->:key) = 'object' THEN plan_notes->:key ELSE '{}'::jsonb END)
          || jsonb_build_object('forgotten_at', CAST(:at AS text)))
    SQL
  end

  def self.clear!(exercise)
    DailyExercise.where(id: exercise.id).update_all([ "plan_notes = plan_notes - ?", KEY ])
    exercise.plan_notes = exercise.plan_notes.except(KEY)
    exercise.clear_attribute_changes([ :plan_notes ])
  end

  def self.change(exercise, response_id: :any)
    exercise.transaction do
      User.lock("FOR SHARE").where(id: exercise.user_id).ids
      exercise.lock!
      next :replaced unless response_id == :any || still_answered_by?(exercise, response_id)

      ledger = Ledger.from(exercise.plan_notes)
      result, changed = yield ledger
      exercise.update!(plan_notes: exercise.plan_notes.merge(KEY => changed.to_h)) if changed
      result
    end
  rescue ActiveRecord::RecordNotFound
    :gone
  end
  private_class_method :change

  def self.still_answered_by?(exercise, response_id)
    DailyResponse.uncached { DailyResponse.submitted.exists?(id: response_id, daily_exercise_id: exercise.id) }
  end
  private_class_method :still_answered_by?
end
