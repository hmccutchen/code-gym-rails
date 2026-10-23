class ApplicationController < ActionController::Base
  # Adds its callback only when PREVIEW_APP is set at boot, which committed config does only for PR deployments.
  include PreviewAutoLogin
  include JsonErrors

  before_action :authenticate_user!,  unless: :devise_controller?
  before_action :require_password,    if: :user_signed_in?, unless: :devise_controller?
  before_action :require_two_factor,  if: :user_signed_in?, unless: :devise_controller?
  before_action :require_provider,    if: :user_signed_in?, unless: :devise_controller?
  around_action :use_time_zone

  # A stale CSRF token (e.g. a login page left open across a deploy) would otherwise be a raw 422.
  rescue_from ActionController::InvalidAuthenticityToken, with: :handle_invalid_token


  private

  def after_sign_in_path_for(user)
    trial = PendingTrial.take(session)
    trial ? pending_trial_destination(user, trial) : super
  end

  def pending_trial_destination(user, trial)
    case trial.start_for(user)
    when :started
      flash[:notice] = t("trials.started")
      root_path
    when :has_own_key
      flash[:alert] = t("trials.has_own_key")
      setup_path
    else
      flash[:alert] = t("trials.code_rejected")
      trial_path
    end
  end

  def handle_invalid_token
    return redirect_to(root_path) if duplicate_login_submit?

    redirect_to new_user_session_path, alert: t("flash.application.session_expired")
  end

  # A double-tapped login form arrives stale after the session rotates; authenticated? reads the session, never the params.
  def duplicate_login_submit?
    warden.authenticated?(:user) && controller_name == "first_sign_ins" && action_name == "verify_code"
  end

  def use_time_zone(&block)
    Time.use_zone(current_user&.effective_time_zone || User::DEFAULT_TIME_ZONE, &block)
  end

  # Page 1 keeps the bare /history URL; every redirect into history goes through here so they can't drift.
  def history_page_path(page)
    history_path(page: (page unless page == 1))
  end

  def own_key?
    current_user.api_key_present?
  end

  def require_password
    redirect_to edit_password_setup_path unless current_user.password_set?
  end

  def require_two_factor
    redirect_to two_factor_setup_path unless current_user.two_factor_enrolled?
  end

  def require_provider
    return if current_user.provider_ready? || current_user.trial?
    return if controller_name == "api_keys"

    redirect_to setup_path, notice: t("flash.application.api_key_needed")
  end
end
