class LearnerNote < ApplicationRecord
  belongs_to :user
  belongs_to :daily_exercise

  MAX_TEXT_LENGTH = 1_000
  KEPT_FOR = 365.days
  REPLY_CLAIM_STALE_AFTER = CallProfiles.worst_case_seconds_for("explanation_reply").seconds + DailyExercise::WRITE_MARGIN

  include Claimable

  self.ignored_columns += %w[extract_attempts extracted_at reply_attempts]

  claim :reply, column: :reply_requested_at, stale_after: REPLY_CLAIM_STALE_AFTER

  self.filter_attributes += %i[body explanation explanation_reply]

  validates :body, :explanation, length: { maximum: MAX_TEXT_LENGTH }
  validate :owned_by_the_sets_owner

  ExplainHistory = Data.define(:recent, :counts)

  scope :explained_before, ->(date) { joins(:daily_exercise).where.not(explanation: nil).where(daily_exercises: { date: ...date }) }

  # Counts by concept name, so a meta-skill concept in both language vocabularies counts once.
  def self.explain_history(before:)
    rows = explained_before(before).pluck(:explain_concept, "daily_exercises.date")
    recent_from = before - ExplainQuestion::RECENT_DAYS
    ExplainHistory.new(recent: rows.filter_map { |concept, date| concept if date >= recent_from }.uniq,
                       counts: rows.map(&:first).tally)
  end

  def self.save_explanation!(exercise, section:, text:, expected_scope:, expected_response_id:)
    transaction do
      owner = User.lock("FOR SHARE").find_by(id: exercise.user_id)
      next :deleted if owner.nil? || owner.anonymized?

      locked = DailyExercise.lock.find_by(id: exercise.id)
      next :stale if locked&.draft_scope != expected_scope

      response = DailyResponse.find_by(daily_exercise_id: exercise.id)
      next :stale if response&.id.to_s != expected_response_id.to_s
      next :not_submitted unless response&.submitted?

      closed = LearnerExtraction.for(locked).closed?
      write(row_for(exercise)) { |note| note.explain(owner, exercise, section, text, closed: closed) }
    end
  end

  # Each writer returns the saved row, or :deleted, :submitted or :stale for what moved while it waited.
  def self.save_body!(exercise, text, question_key:, expected_scope:, expected_response_id:)
    body = UserText.clean(text, limit: MAX_TEXT_LENGTH)
    under_draft_locks(exercise, expected_scope, expected_response_id) do
      write(row_for(exercise)) do |note|
        note.body = body
        note.question_key ||= question_key if body.strip.present?
      end
    end
  end

  def self.for_set(exercise) = find_by(daily_exercise_id: exercise.id)

  FORGOTTEN_COLUMNS = {
    note: { body: nil, question_key: nil },
    explanation: { explain_section: nil, explain_concept: nil, explain_phrasing: nil, explanation: nil,
                   explanation_reply: nil, reply_requested_at: nil }
  }.freeze

  scope :expired, ->(today = Date.current) { where(daily_exercise: DailyExercise.where(date: ...(today - KEPT_FOR))) }

  scope :written, -> { where("btrim(coalesce(body, '')) <> '' OR explanation IS NOT NULL") }

  def self.listed(user) = user.learner_notes.written.joins(:daily_exercise).includes(:daily_exercise).order("daily_exercises.date DESC")

  def self.remove!(user, id, part)
    LearnerItem.under_owner_lock(user) do |owner|
      note = owner.learner_notes.includes(:daily_exercise).lock.find_by(id: id)
      next :missing unless note&.holds?(part)

      note.forget!(part)
      :removed
    end
  end

  def self.remove_all!(user)
    LearnerItem.under_owner_lock(user) do |owner|
      owner.learner_items.delete_all
      owner.learner_notes.delete_all
      LearnerExtraction.forget_all!(owner)
      :removed
    end
  end

  # The caller holds the user row lock, since every item citing this set's note or explanation goes with it.
  def self.forget_set!(exercise)
    for_set(exercise)&.forget!(*FORGOTTEN_COLUMNS.keys)
  end

  # A page rendered before any response existed posts none, and its first answer save creates one it never hears about.
  def self.under_draft_locks(exercise, expected_scope, expected_response_id)
    transaction do
      owner = User.lock("FOR SHARE").find_by(id: exercise.user_id)
      next :deleted if owner.nil? || owner.anonymized?

      exercise.with_response_locked do |response|
        next :stale if expected_response_id.present? && response&.id.to_s != expected_response_id
        next :submitted if response&.submitted?
        next :stale if exercise.draft_scope != expected_scope

        yield
      end
    end
  rescue ActiveRecord::RecordNotFound
    :stale
  end
  private_class_method :under_draft_locks

  def self.row_for(exercise)
    transaction(requires_new: true) do
      find_or_create_by!(daily_exercise: exercise) { |row| row.user = exercise.user }
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(daily_exercise: exercise)
  end
  private_class_method :row_for

  def self.write(note)
    note.with_lock do
      refusal = yield note
      next refusal if refusal.is_a?(Symbol)

      note.save!
      note
    end
  end
  private_class_method :write

  def explain(owner, exercise, section, text, closed:)
    return :explained if explanation.present?
    return :closed if closed

    option = ExplainQuestion.options(tags: exercise.section_concepts).find { |held| held.section == section }
    return :not_an_option unless option

    earlier = owner.learner_notes.explain_history(before: exercise.date).counts.fetch(option.concept, 0)
    assign_attributes(explain_section: option.section, explain_concept: option.concept,
                      explain_phrasing: ExplainQuestion.phrasing(earlier), explanation: text)
    nil
  end

  def reply = ExplanationReply.from_stored(explanation_reply)

  def reply_state(attempts)
    return :replied if reply
    return :waiting if reply? || attempts.zero?

    attempts < LearnerExtraction::MAX_REPLY_ATTEMPTS ? :failed_retry : :failed_final
  end

  def reply_askable?(attempts) = reply_state(attempts) == :waiting && !reply?

  # Returns the claim's token, or :replied, :busy, :exhausted or :gone; the set counts the attempt with the claim.
  def start_reply!
    LearnerExtraction.count_reply_attempt!(daily_exercise) do |spent|
      note = self.class.lock.find_by(id: id)
      next :gone if note&.explanation.blank?
      next :replied if note.reply
      next :busy if note.reply?
      next :exhausted if spent

      note.claim_reply! || :busy
    end
  end

  def finish_reply!(token, reply)
    transaction do
      note = self.class.lock.find_by(id: id)
      next :gone unless note
      next :moved unless note.reply_requested_at == token

      note.update!(explanation_reply: reply.to_h, reply_requested_at: nil)
      :stored
    end
  end

  def holds?(part) = part == :note ? body.to_s.strip.present? : explanation.present?

  def forget!(*parts)
    LearnerItem.forget_citing!(user, date: daily_exercise.date, sources: parts.map(&:to_s))
    assign_attributes(parts.map { |part| FORGOTTEN_COLUMNS.fetch(part) }.reduce(:merge))
    holds?(:note) || holds?(:explanation) ? save! : delete
  end

  def something_to_read? = body.to_s.strip.present? || explanation.to_s.strip.present?

  private

  def owned_by_the_sets_owner
    errors.add(:user, "must own the set") unless daily_exercise && user_id == daily_exercise.user_id
  end
end
