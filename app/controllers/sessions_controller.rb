class SessionsController < ApplicationController
  include LoginCodeRequests
  include SignInCompletion

  skip_before_action :require_login
  skip_before_action :require_provider

  helper_method :pending_login_email

  RATE_LIMIT_STORE = LazyCacheStore.new

  limit_login_code_requests only: :create

  rate_limit to: 10, within: User::LOGIN_RATE_LIMIT_WINDOW,
             with:  -> { code_attempts_limited },
             store: RATE_LIMIT_STORE,
             name:  "code_attempts",
             only:  :verify_code

  rate_limit to: 10, within: 1.hour,
             by:    -> { pending_login_email || request.remote_ip },
             with:  -> { code_attempts_limited },
             store: RATE_LIMIT_STORE,
             name:  "code_attempts_for_address",
             only:  :verify_code

  # GET /login
  def new
    return redirect_to root_path if logged_in?

    redirect_to login_code_path if pending_login_email.present?
  end

  # POST /login — an account with an authenticator skips the email; the pending state makes a code redeemable here.
  def create
    PendingTrial.forget(session)
    authenticator_user = User.active.find_by(email: normalized_email)
    return start_second_factor_challenge(authenticator_user) if authenticator_user&.two_factor_enabled?

    mail_login_code(normalized_email)
    redirect_to login_code_path,
                notice: t("sessions.code_sent", expiry: User.login_code_expiry_in_words)
  rescue ActiveRecord::RecordInvalid
    flash.now[:alert] = t("sessions.email_not_accepted")
    render :new, status: :unprocessable_content
  end

  # GET /login/code
  def enter_code
    return redirect_to root_path if logged_in?

    redirect_to login_path if pending_login_email.blank?
  end

  # DELETE /login/code
  def start_over
    session.delete(:pending_login_email)
    session.delete(:pending_login_at)
    redirect_to login_path
  end

  # POST /login/code — the email comes from this browser's session, never a form field.
  def verify_code
    checked_at = Time.current
    email = pending_login_email
    user  = email.present? ? User.authenticate_login_code(email: email, code: params[:code].to_s) : nil
    user ? remember_sign_in(user, login_code_proof(email)) : user = repeated_login(email)
    return reject_login_code(email) unless user
    return start_second_factor_challenge(user) if user.two_factor_enabled?

    complete_sign_in(user, checked_at: checked_at)
  end

  def destroy
    reset_session
    redirect_to login_path, notice: t("sessions.logged_out")
  end

  private

  def login_code_proof(email) = [ email, session[:pending_login_at], params[:code].to_s ]

  def repeated_login(email)
    user = email.present? ? User.active.find_by(email: email) : nil
    return unless repeat_of_recent_sign_in?(user, login_code_proof(email))

    PendingTrial.forget(session)
    user
  end

  def reject_login_code(email)
    return redirect_to login_path, alert: t("sessions.code_rejected_request_new") if email.blank?

    @code_rejected = true
    flash.now[:alert] = t("sessions.code_rejected_retry")
    render :enter_code, status: :unprocessable_content
  end

  def code_attempts_limited
    flash.now[:alert] = t("sessions.rate_limited.code_attempts")
    render :enter_code, status: :too_many_requests
  end

  def login_code_requests_limited(message)
    flash.now[:alert] = message
    render :new, status: :too_many_requests
  end

  def pending_login_email
    return nil if pending_login_expired?

    session[:pending_login_email].presence
  end

  # An unreadable stamp counts as still pending: a stale banner is cheaper than rejecting a live code after a deploy.
  def pending_login_expired?
    stamped_at = session[:pending_login_at]
    return false if stamped_at.blank?

    !User.login_pending?(email: session[:pending_login_email], requested_at: Time.iso8601(stamped_at.to_s))
  rescue ArgumentError
    false
  end
end
