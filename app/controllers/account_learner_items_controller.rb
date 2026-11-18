class AccountLearnerItemsController < ApplicationController
  skip_before_action :require_provider

  # PATCH /account/learner_items/:id/got_it
  def got_it
    answer(LearnerItem.dismiss!(current_user, params[:id]))
  end

  def destroy
    answer(LearnerItem.remove!(current_user, params[:id]))
  end

  private

  def answer(outcome)
    case outcome
    when :dismissed    then back_to_section(notice: t("flash.accounts.learner_item_dismissed"))
    when :removed      then back_to_section(notice: t("flash.accounts.learner_item_removed"))
    when :closed       then back_to_section(alert: t("flash.accounts.learner_item_closed"))
    when :missing      then back_to_section(alert: t("flash.accounts.learner_notes_missing"))
    when :account_gone then redirect_to login_path, alert: t("flash.application.login_required")
    else raise ArgumentError, "Unhandled learner item outcome: #{outcome.inspect}"
    end
  end

  def back_to_section(**flash) = redirect_to(account_path(anchor: "learner-notes"), **flash)
end
