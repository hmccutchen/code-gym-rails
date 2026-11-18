class LearnerNote < ApplicationRecord
  belongs_to :user
  belongs_to :daily_exercise

  MAX_TEXT_LENGTH = 1_000
  MAX_EXTRACT_ATTEMPTS = 2
  MAX_REPLY_ATTEMPTS = 2
  REPLY_CLAIM_STALE_AFTER = CallProfiles.worst_case_seconds_for("explanation_reply").seconds + DailyExercise::WRITE_MARGIN

  include Claimable

  claim :reply, column: :reply_requested_at, stale_after: REPLY_CLAIM_STALE_AFTER

  self.filter_attributes += %i[body explanation explanation_reply]

  validates :body, :explanation, length: { maximum: MAX_TEXT_LENGTH }
  validates :extract_attempts, numericality: { only_integer: true, in: 0..MAX_EXTRACT_ATTEMPTS }
  validates :reply_attempts, numericality: { only_integer: true, in: 0..MAX_REPLY_ATTEMPTS }
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

  def self.save_explanation!(exercise, section:, text:, expected_scope:)
    transaction do
      owner = User.lock("FOR SHARE").find_by(id: exercise.user_id)
      next :deleted if owner.nil? || owner.anonymized?
      next :stale if DailyExercise.find_by(id: exercise.id)&.draft_scope != expected_scope
      next :not_submitted unless exercise.daily_response&.submitted?

      write(row_for(exercise)) { |note| note.explain(owner, exercise, section, text) }
    end
  end

  # Each writer returns the saved row, or :deleted, :submitted or :stale for what moved while it waited.
  def self.save_body!(exercise, text, question_key:, expected_scope:)
    body = UserText.clean(text, limit: MAX_TEXT_LENGTH)
    under_draft_locks(exercise, expected_scope) do
      write(row_for(exercise)) do |note|
        note.body = body
        note.question_key ||= question_key if body.strip.present?
      end
    end
  end

  def self.extraction_row(exercise) = row_for(exercise)

  FORGOTTEN_COLUMNS = {
    note: { body: nil, question_key: nil },
    explanation: { explain_section: nil, explain_concept: nil, explain_phrasing: nil, explanation: nil,
                   explanation_reply: nil, reply_requested_at: nil }
  }.freeze

  scope :written, -> { where("btrim(coalesce(body, '')) <> '' OR explanation IS NOT NULL") }

  def self.listed(user) = user.learner_notes.written.joins(:daily_exercise).includes(:daily_exercise).order("daily_exercises.date DESC")

  def self.remove!(user, id, part)
    LearnerItem.under_owner_lock(user) do |owner|
      note = owner.learner_notes.includes(:daily_exercise).find_by(id: id)
      next :missing unless note&.holds?(part)

      note.forget!(part)
      :removed
    end
  end

  def self.remove_all!(user)
    LearnerItem.under_owner_lock(user) do |owner|
      owner.learner_items.delete_all
      owner.learner_notes.includes(:daily_exercise).find_each { |note| note.forget!(*FORGOTTEN_COLUMNS.keys) }
      :removed
    end
  end

  # The caller holds the user row lock, since items lose this set's note and explanation evidence with it.
  def self.forget_set!(exercise)
    note = find_by(daily_exercise_id: exercise.id)
    return unless note

    LearnerItem.forget_evidence!(note.user, date: exercise.date, sources: LearnerItem::WRITTEN_SOURCES)
    note.delete
  end

  def self.under_draft_locks(exercise, expected_scope)
    transaction do
      owner = User.lock("FOR SHARE").find_by(id: exercise.user_id)
      next :deleted if owner.nil? || owner.anonymized?

      exercise.with_response_locked do |response|
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

  def explain(owner, exercise, section, text)
    return :explained if explanation.present?
    return :closed if extracted_at.present?

    option = ExplainQuestion.options(tags: exercise.section_concepts).find { |held| held.section == section }
    return :not_an_option unless option

    earlier = owner.learner_notes.explain_history(before: exercise.date).counts.fetch(option.concept, 0)
    assign_attributes(explain_section: option.section, explain_concept: option.concept,
                      explain_phrasing: ExplainQuestion.phrasing(earlier), explanation: text)
    nil
  end

  def extracted? = extracted_at.present?

  def close_extraction!
    with_lock { update!(extracted_at: Time.current) unless extracted? }
  end

  # The attempt is saved before the call leaves, so a worker that dies mid-call has already spent it.
  def count_extract_attempt!(close:)
    with_lock do
      next false if extracted? || extract_attempts >= MAX_EXTRACT_ATTEMPTS

      update!(extract_attempts: extract_attempts + 1, extracted_at: (Time.current if close))
      true
    end
  end

  def reply = ExplanationReply.from_stored(explanation_reply)

  def reply_state
    return :replied if reply
    return :waiting if reply? || reply_attempts.zero?

    reply_attempts < MAX_REPLY_ATTEMPTS ? :failed_retry : :failed_final
  end

  def reply_askable? = reply_state == :waiting && !reply?

  # Returns the claim's token, or :replied, :busy or :exhausted; the attempt is counted with the claim.
  def start_reply!
    with_lock do
      next :replied if reply
      next :busy if reply?
      next :exhausted if reply_attempts >= MAX_REPLY_ATTEMPTS

      token = claim_reply!
      next :busy unless token

      update!(reply_attempts: reply_attempts + 1)
      token
    end
  end

  def finish_reply!(token, reply)
    with_lock do
      next :moved unless reply_requested_at == token

      update!(explanation_reply: reply.to_h, reply_requested_at: nil)
    end
  end

  def holds?(part) = part == :note ? body.to_s.strip.present? : explanation.present?

  def forget!(*parts)
    LearnerItem.forget_evidence!(user, date: daily_exercise.date, sources: parts.map(&:to_s))
    assign_attributes(parts.map { |part| FORGOTTEN_COLUMNS.fetch(part) }.reduce(:merge))
    nothing_left = !holds?(:note) && !holds?(:explanation)
    nothing_left && !read_by_a_request? ? delete : save!
  end

  def read_by_a_request? = extract_attempts.positive? || extracted? || reply_attempts.positive?

  def something_to_read? = body.to_s.strip.present? || explanation.to_s.strip.present?

  private

  def owned_by_the_sets_owner
    errors.add(:user, "must own the set") unless daily_exercise && user_id == daily_exercise.user_id
  end
end
