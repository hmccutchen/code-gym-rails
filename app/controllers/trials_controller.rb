# GET /trial, POST /trial — redeem an invite code for a trial on a house key.
# Login stays the emailed code, so every trial user has an account first.
class TrialsController < ApplicationController
  skip_before_action :require_provider

  RATE_LIMIT_STORE = LazyCacheStore.new

  # A code is a secret, so guessing is bounded per account and per IP.
  rate_limit to: 5, within: 1.hour, by: -> { current_user.id },
             with: -> { redirect_to trial_path, alert: t("trials.rate_limited") },
             store: RATE_LIMIT_STORE, name: "redemptions_by_account", only: :create

  rate_limit to: 10, within: 1.hour,
             with: -> { redirect_to trial_path, alert: t("trials.rate_limited") },
             store: RATE_LIMIT_STORE, name: "redemptions_by_ip", only: :create

  # GET /trial — the form, or the trial's standing for an account on one. A
  # first-run account answers the experience question first, as on Setup.
  def show
    return redirect_to welcome_path if current_user.first_run?

    @status = TrialStatus.for(current_user) if current_user.trial?
  end

  def create
    unless params[:consent] == "1"
      return redirect_to trial_path, alert: t("trials.consent_needed")
    end

    if current_user.start_trial!(code: params[:invite_code], consented_at: Time.current)
      redirect_to root_path, notice: t("trials.started")
    else
      redirect_to trial_path, alert: t("trials.code_rejected")
    end
  end
end
