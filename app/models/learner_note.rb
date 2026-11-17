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
      yield note
      note.save!
      note
    end
  end
  private_class_method :write

  private

  def owned_by_the_sets_owner
    errors.add(:user, "must own the set") unless daily_exercise && user_id == daily_exercise.user_id
  end
end
