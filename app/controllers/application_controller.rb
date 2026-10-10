class ApplicationController < ActionController::Base
  # Adds its callback only when PREVIEW_APP is set at boot, which committed config does only for PR deployments.
  include PreviewAutoLogin

  before_action :require_login
  before_action :require_provider
  around_action :use_time_zone

  # A stale CSRF token (e.g. a login page left open across a deploy) would otherwise be a raw 422.
  rescue_from ActionController::InvalidAuthenticityToken, with: :handle_invalid_token

  helper_method :current_user, :logged_in?

  private

  def handle_invalid_token
    return redirect_to(root_path) if duplicate_login_submit?

    redirect_to login_path, alert: t("flash.application.session_expired")
  end

  # A double-tapped login form arrives stale after the session rotates; logout is excluded so a failed sign-out shows.
  def duplicate_login_submit?
    logged_in? && controller_name == "sessions" && %w[create verify_code].include?(action_name)
  end

  def use_time_zone(&block)
    Time.use_zone(current_user&.effective_time_zone || User::DEFAULT_TIME_ZONE, &block)
  end

  # Page 1 keeps the bare /history URL; every redirect into history goes through here so they can't drift.
  def history_page_path(page)
    history_path(page: (page unless page == 1))
  end

  # Scoped to `active` so an anonymized user's open session in another tab stops resolving on its next request.
  def current_user
    @current_user ||= User.active.find_by(id: session[:user_id])
  end

  def logged_in?
    current_user.present?
  end

  # The per-user limits guard a trial's house key; an account with its own key is never limited.
  def own_key?
    current_user.api_key_present?
  end

  def require_login
    unless logged_in?
      session[:return_to] = request.fullpath
      redirect_to login_path, alert: t("flash.application.login_required")
    end
  end

  # An ended trial still reaches every page; each provider call then fails with the trial-ended sentence.
  def require_provider
    return unless logged_in?
    return if current_user.provider_ready? || current_user.trial?
    return if controller_name == "api_keys" || controller_name == "sessions"

    redirect_to setup_path, notice: t("flash.application.api_key_needed")
  end
end
