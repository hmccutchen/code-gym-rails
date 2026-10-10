# GET/POST /trial/start for a signed-out visitor; GET/POST /trial for a signed-in account with no key.
class TrialsController < ApplicationController
  include LoginCodeRequests

  skip_before_action :require_login, only: %i[new start show]
  skip_before_action :require_provider

  RATE_LIMIT_STORE = LazyCacheStore.new

  limit_login_code_requests only: :start

  # A code is a secret, so guessing is bounded per account and per IP.
  rate_limit to: 5, within: 1.hour, by: -> { current_user.id },
             with: -> { redemption_limited },
             store: RATE_LIMIT_STORE, name: "redemptions_by_account", only: :create

  rate_limit to: 10, within: 1.hour,
             with: -> { redemption_limited },
             store: RATE_LIMIT_STORE, name: "redemptions_by_ip", only: %i[create start]

  def new
    return redirect_to trial_path if logged_in?

    @providers = TrialMode.providers
  end

  def start
    return redirect_to trial_path if logged_in?

    invite = InviteCode.find_by_code(params[:invite_code])
    return refuse_start(t("trials.consent_needed")) unless params[:consent] == "1"
    return refuse_start(t("trials.code_rejected")) unless invite&.available?
    return refuse_start(t("trials.provider_needed")) unless TrialMode.providers.include?(params[:provider])

    email = normalized_email
    mail_login_code(email, params[:name].to_s.strip)
    PendingTrial.remember(session, email: email, invite: invite, provider: params[:provider], consented_at: Time.current)
    redirect_to login_path, notice: t("trials.code_sent", expiry: User.login_code_expiry_in_words)
  rescue ActiveRecord::RecordInvalid
    refuse_start(t("sessions.email_not_accepted"))
  end

  # GET /trial — the first-run hop keeps the flash, since a trial refused at sign-in lands here first.
  def show
    return redirect_to new_trial_path unless logged_in?
    return redirect_to(welcome_path).tap { flash.keep } if current_user.first_run?
    return redirect_to setup_path, alert: t("trials.has_own_key") if current_user.api_key_present?

    @status = TrialStatus.for(current_user) if current_user.on_trial?
  end

  def create
    return redirect_to setup_path, alert: t("trials.has_own_key") if current_user.api_key_present?
    return redirect_to trial_path, alert: t("trials.consent_needed") unless params[:consent] == "1"
    return redirect_to trial_path, alert: t("trials.provider_needed") unless TrialMode.providers.include?(params[:provider])

    invite = InviteCode.find_by_code(params[:invite_code])
    if current_user.start_trial!(invite: invite, provider: params[:provider], consented_at: Time.current)
      redirect_to root_path, notice: t("trials.started")
    else
      redirect_to trial_path, alert: t("trials.code_rejected")
    end
  end

  private

  # Kept on the form with what was typed, so a slip does not cost the rest.
  def refuse_start(message)
    @providers = TrialMode.providers
    flash.now[:alert] = message
    render :new, status: :unprocessable_content
  end

  def redemption_limited
    redirect_to logged_in? ? trial_path : new_trial_path, alert: t("trials.rate_limited")
  end

  def login_code_requests_limited(message)
    @providers = TrialMode.providers
    flash.now[:alert] = message
    render :new, status: :too_many_requests
  end
end
