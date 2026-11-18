# Design notes: docs/code-notes/app/models/learner_extraction.md
module LearnerExtraction
  KEY = "learner_extraction".freeze
  MAX_ATTEMPTS = 2
  MAX_REPLY_ATTEMPTS = 2

  Ledger = Data.define(:attempts, :closed_at, :reply_attempts) do
    def self.from(plan_notes)
      stored = plan_notes.is_a?(Hash) ? plan_notes[KEY] : nil
      stored = {} unless stored.is_a?(Hash)
      new(attempts: stored["attempts"].to_i, closed_at: stored["closed_at"], reply_attempts: stored["reply_attempts"].to_i)
    end

    def closed? = closed_at.present?

    def to_h = { "attempts" => attempts, "closed_at" => closed_at, "reply_attempts" => reply_attempts }.compact
  end

  def self.for(exercise) = Ledger.from(exercise.plan_notes)

  # Returns true when the attempt was counted, false when the set is closed or spent, or :gone.
  def self.count_attempt!(exercise, close:)
    change(exercise) do |ledger|
      next false if ledger.closed? || ledger.attempts >= MAX_ATTEMPTS

      [ true, ledger.with(attempts: ledger.attempts + 1, closed_at: (Time.current.iso8601 if close)) ]
    end
  end

  def self.close!(exercise)
    change(exercise) do |ledger|
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

  def self.clear!(exercise)
    DailyExercise.where(id: exercise.id).update_all([ "plan_notes = plan_notes - ?", KEY ])
    exercise.plan_notes = exercise.plan_notes.except(KEY)
    exercise.clear_attribute_changes([ :plan_notes ])
  end

  def self.change(exercise)
    exercise.transaction do
      User.lock("FOR SHARE").where(id: exercise.user_id).ids
      exercise.lock!
      ledger = Ledger.from(exercise.plan_notes)
      result, changed = yield ledger
      exercise.update!(plan_notes: exercise.plan_notes.merge(KEY => changed.to_h)) if changed
      result
    end
  rescue ActiveRecord::RecordNotFound
    :gone
  end
  private_class_method :change
end
