class AccountsController < ApplicationController
  include RecentSignIn
  include LearnerNotesGate

  # The log-out and delete buttons live here, so a keyless user must not be redirected to /setup.
  skip_before_action :require_provider

  LearnerLists = Data.define(:open, :dismissed, :written)

  PAUSE_NOTICES = { paused: "flash.accounts.generation_paused", kept: "flash.accounts.generation_kept_paused" }.freeze

  # GET /account
  def show
    now = Time.current.in_time_zone(current_user.effective_time_zone)
    @usage_since = now.beginning_of_month
    @usage = MonthlySpend.new(totals: ApiUsage.own_key_totals(current_user, since: @usage_since), today: now.to_date, paused: current_user.paused_generation_at?)
    @learner_lists = learner_lists(now.to_date) if learner_notes_listed?
  end

  # DELETE /account
  def destroy
    return send_through_sign_in(return_to: account_path, notice: t("flash.accounts.sign_in_to_delete")) unless signed_in_recently?

    outcome = AccountDeletion.call(current_user)

    case outcome.status
    when :deleted, :already_deleted
      reset_session
      redirect_to login_path, notice: t("flash.accounts.deleted")
    else raise ArgumentError, "Unhandled account deletion outcome: #{outcome.status}"
    end
  end

  # PATCH /account/toggle_generation
  def toggle_generation
    if resume_requested?
      held = current_user.resume_generation!
      notice = held ? "flash.accounts.generation_resumed_with_held_set" : "flash.accounts.generation_resumed"
    else
      notice = PAUSE_NOTICES.fetch(current_user.pause_generation!(source: User::MANUAL_PAUSE))
    end
    redirect_to after_toggle_path, notice: t(notice)
  end

  # PATCH /account/learner_notes
  def learner_notes
    return head(:not_found) unless LearnerNotes.enabled?

    case write_learner_notes_setting(params[:enabled] == "1")
    when :saved          then redirect_to account_path, notice: t(learner_notes_notice)
    when :own_key_needed then redirect_to account_path, alert: t("flash.accounts.learner_notes_need_own_key")
    when :deleted        then redirect_to login_path, alert: t("flash.application.login_required")
    else raise ArgumentError, "Unhandled learner notes setting outcome"
    end
  end

  private

  def learner_lists(today)
    LearnerLists.new(open: LearnerItem.listed_open(current_user, today: today).to_a,
                     dismissed: LearnerItem.recently_dismissed(current_user, today: today).to_a,
                     written: LearnerNote.listed(current_user).to_a)
  end

  def learner_notes_notice
    current_user.learner_notes_enabled? ? "flash.accounts.learner_notes_on" : "flash.accounts.learner_notes_off"
  end

  # Turning the setting off needs no key, so an account that lost its own key can still stop its notes.
  def write_learner_notes_setting(wanted)
    return :own_key_needed if wanted && !learner_notes_offered?

    current_user.with_lock do
      next :deleted if current_user.anonymized?

      current_user.update!(learner_notes_enabled: wanted)
      :saved
    end
  rescue ActiveRecord::RecordNotFound
    :deleted
  end

  # A fixed name, never a URL, so the form's return_to cannot send the browser off this site.
  def after_toggle_path = params[:return_to] == "dashboard" ? root_path : account_path

  # Honor the posted state so a double-tapped Resume stays a resume; with no param posted, flip.
  def resume_requested?
    return params[:paused] == "0" if params.key?(:paused)

    current_user.paused_generation_at?
  end
end
