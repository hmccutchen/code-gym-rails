class SessionsController < ApplicationController
  include LoginCodeRequests
  include SignInCompletion

  skip_before_action :require_login
  skip_before_action :require_provider

  helper_method :pending_login_email

  RATE_LIMIT_STORE = LazyCacheStore.new

  limit_login_code_requests only: :create

  rate_limit to: 10, within: User::LOGIN_RATE_LIMIT_WINDOW,
             with:  -> { rate_limited(t("sessions.rate_limited.code_attempts")) },
             store: RATE_LIMIT_STORE,
             name:  "code_attempts",
             only:  :verify_code

  rate_limit to: 10, within: 1.hour,
             by:    -> { pending_login_email || request.remote_ip },
             with:  -> { rate_limited(t("sessions.rate_limited.code_attempts")) },
             store: RATE_LIMIT_STORE,
             name:  "code_attempts_for_address",
             only:  :verify_code

  # GET /login
  def new
    redirect_to root_path if logged_in?
  end

  # POST /login — the pending state written here is what makes the code redeemable in this browser.
  def create
    PendingTrial.forget(session)
    mail_login_code(normalized_email)

    redirect_to login_path,
                notice: t("sessions.code_sent", expiry: User.login_code_expiry_in_words)
  rescue ActiveRecord::RecordInvalid
    flash.now[:alert] = t("sessions.email_not_accepted")
    render :new, status: :unprocessable_content
  end

  # POST /login/code — the email comes from this browser's session, never a form field.
  def verify_code
    checked_at = Time.current
    email = pending_login_email
    user  = email.present? ? User.authenticate_login_code(email: email, code: params[:code].to_s) : nil
    return reject_login_code(email) unless user
    return start_second_factor_challenge(user) if user.two_factor_enabled?

    complete_sign_in(user, checked_at: checked_at)
  end

  def destroy
    reset_session
    redirect_to login_path, notice: t("sessions.logged_out")
  end

  private

  def reject_login_code(email)
    @code_rejected = true
    flash.now[:alert] =
      email.present? ? t("sessions.code_rejected_retry") : t("sessions.code_rejected_request_new")
    render :new, status: :unprocessable_content
  end

  def login_code_requests_limited(message) = rate_limited(message)

  def rate_limited(message)
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
