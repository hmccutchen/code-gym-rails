# Design notes: docs/code-notes/app/controllers/account_learner_notes_controller.md
class AccountLearnerNotesController < ApplicationController
  skip_before_action :require_provider

  # DELETE /account/learner_notes/:id/note
  def destroy_note
    remove(:note, "flash.accounts.learner_note_removed")
  end

  # DELETE /account/learner_notes/:id/explanation
  def destroy_explanation
    remove(:explanation, "flash.accounts.learner_explanation_removed")
  end

  # DELETE /account/learner_notes/all
  def destroy_all
    outcome = LearnerNote.remove_all!(current_user)
    ExtractLearnerItemsJob.discard_waiting(current_user) if outcome == :removed
    answer(outcome, "flash.accounts.learner_notes_all_removed")
  end

  private

  def remove(part, notice)
    set_id = current_user.learner_notes.where(id: params[:id]).pick(:daily_exercise_id)
    outcome = LearnerNote.remove!(current_user, params[:id], part)
    ExtractLearnerItemsJob.discard_waiting(current_user, daily_exercise_id: set_id) if outcome == :removed
    answer(outcome, notice)
  end

  def answer(outcome, notice)
    case outcome
    when :removed      then back_to_section(notice: t(notice))
    when :missing      then back_to_section(alert: t("flash.accounts.learner_notes_missing"))
    when :account_gone then redirect_to login_path, alert: t("flash.application.login_required")
    else raise ArgumentError, "Unhandled learner note outcome: #{outcome.inspect}"
    end
  end

  def back_to_section(**flash) = redirect_to(account_path(anchor: "learner-notes"), **flash)
end
