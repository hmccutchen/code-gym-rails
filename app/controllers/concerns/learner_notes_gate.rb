module LearnerNotesGate
  extend ActiveSupport::Concern

  included do
    helper_method :learner_notes_offered?, :learner_notes_on?, :learner_notes_setting
  end

  private

  def learner_notes_offered? = LearnerNotes.offered_to?(current_user)

  def learner_notes_on? = LearnerNotes.on_for?(current_user)

  # :on_without_key keeps the turn-off control for an account that lost its own key with the setting on.
  def learner_notes_setting
    return unless LearnerNotes.enabled?
    return :on if learner_notes_on?
    return :on_without_key if current_user.learner_notes_enabled?

    :off if learner_notes_offered?
  end

  def learner_notes_listed?
    learner_notes_setting.present? || current_user.learner_notes.exists? || current_user.learner_items.exists?
  end
end
