class ApplicationController < ActionController::Base
  before_action :require_login
  before_action :require_api_key
  around_action :use_time_zone

  # A stale CSRF token (e.g. a login page left open across a deploy restart)
  # would otherwise surface as a raw 422. Send the user back to log in fresh.
  rescue_from ActionController::InvalidAuthenticityToken, with: :handle_invalid_token

  helper_method :current_user, :logged_in?

  private

  def handle_invalid_token
    return redirect_to(root_path) if duplicate_login_submit?

    redirect_to login_path, alert: "Your session expired — please try again."
  end

  # Logging in rotates the session (and its CSRF token), which leaves the login
  # forms — rendered under the pre-login session — stale the instant they
  # succeed. A re-submit (a double-tap on mobile) then lands here with the user
  # already logged in. The request is still blocked; it just isn't worth telling
  # someone who just authenticated that their session expired and bouncing them
  # to a login page that only redirects back. Deliberately excludes logout:
  # silently returning someone to the dashboard when they asked to sign out
  # would hide a failure they do care about.
  def duplicate_login_submit?
    logged_in? && controller_name == "sessions" && %w[create verify_code].include?(action_name)
  end

  def use_time_zone(&block)
    Time.use_zone(current_user&.effective_time_zone || User::DEFAULT_TIME_ZONE, &block)
  end

  # Scoped to `active` so an anonymized user's still-open session (another tab,
  # another device) stops resolving at its very next request.
  def current_user
    @current_user ||= User.active.find_by(id: session[:user_id])
  end

  def logged_in?
    current_user.present?
  end

  def require_login
    unless logged_in?
      session[:return_to] = request.fullpath
      redirect_to login_path, alert: "Please log in first."
    end
  end

  def require_api_key
    return unless logged_in?
    return if current_user.api_key_present?
    return if controller_name == "api_keys" || controller_name == "sessions"

    redirect_to setup_path, notice: "Add your API key to get started."
  end
end
