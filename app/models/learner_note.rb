class LearnerNote < ApplicationRecord
  belongs_to :user
  belongs_to :daily_exercise

  MAX_TEXT_LENGTH = 1_000
  MAX_EXTRACT_ATTEMPTS = 2
  MAX_REPLY_ATTEMPTS = 2

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

  def self.save_explanation!(exercise, section:, text:)
    transaction do
      owner = User.lock("FOR SHARE").find_by(id: exercise.user_id)
      next :deleted if owner.nil? || owner.anonymized?
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

  def something_to_read? = body.to_s.strip.present? || explanation.to_s.strip.present?

  private

  def owned_by_the_sets_owner
    errors.add(:user, "must own the set") unless daily_exercise && user_id == daily_exercise.user_id
  end
end
