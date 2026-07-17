class ApplicationController < ActionController::Base
  before_action :require_login
  before_action :require_api_key
  around_action :use_time_zone

  helper_method :current_user, :logged_in?

  private

  def use_time_zone(&block)
    Time.use_zone(current_user&.effective_time_zone || User::DEFAULT_TIME_ZONE, &block)
  end

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
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
