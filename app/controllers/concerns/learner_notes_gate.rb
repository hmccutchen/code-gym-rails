module LearnerNotesGate
  extend ActiveSupport::Concern

  included do
    helper_method :learner_notes_offered?, :learner_notes_on?
  end

  private

  def learner_notes_offered? = LearnerNotes.enabled? && own_key?

  def learner_notes_on? = learner_notes_offered? && current_user.learner_notes_enabled?

  def learner_notes_listed?
    learner_notes_offered? || current_user.learner_notes.exists? || current_user.learner_items.exists?
  end
end
