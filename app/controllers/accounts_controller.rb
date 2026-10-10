class AccountsController < ApplicationController
  # The log-out and delete buttons live here, so a keyless user must not be redirected to /setup.
  skip_before_action :require_provider

  # GET /account
  def show; end

  # DELETE /account
  def destroy
    current_user.anonymize!
    reset_session
    redirect_to login_path, notice: t("flash.accounts.deleted")
  end

  # PATCH /account/toggle_generation
  def toggle_generation
    if resume_requested?
      resumed = current_user.resume_generation!
      notice = if resumed
        t("flash.accounts.generation_resumed_with_held_set")
      else
        t("flash.accounts.generation_resumed")
      end
      redirect_to account_path, notice: notice
    else
      # Re-stamping would move #held_exercise's floor past the set the first pause stranded, losing it for good.
      current_user.update!(paused_generation_at: Time.current) unless current_user.paused_generation_at?
      redirect_to account_path, notice: t("flash.accounts.generation_paused")
    end
  end

  private

  # Honor the posted state so a double-tapped Resume stays a resume; with no param posted, flip.
  def resume_requested?
    return params[:paused] == "0" if params.key?(:paused)

    current_user.paused_generation_at?
  end
end
