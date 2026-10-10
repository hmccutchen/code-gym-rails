class SessionsController < ApplicationController
  include LoginCodeRequests

  skip_before_action :require_login
  skip_before_action :require_provider

  helper_method :pending_login_email

  RATE_LIMIT_STORE = LazyCacheStore.new

  limit_login_code_requests only: :create

  # Every limit needs a distinct `name:`, or Rails keys them into one shared bucket per controller.
  rate_limit to: 10, within: User::LOGIN_CODE_EXPIRY,
             with:  -> { rate_limited(t("sessions.rate_limited.code_attempts")) },
             store: RATE_LIMIT_STORE,
             name:  "code_attempts",
             only:  :verify_code

  # Caps guesses per address against rotating IPs; hourly, because anyone can trigger this lockout for any address.
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
    mail_login_code(normalized_email, params[:name].to_s.strip)

    redirect_to login_path,
                notice: t("sessions.code_sent", expiry: User.login_code_expiry_in_words)
  rescue ActiveRecord::RecordInvalid
    flash.now[:alert] = t("sessions.email_not_accepted")
    render :new, status: :unprocessable_content
  end

  # POST /login/code — the email comes from this browser's session, never a form field.
  def verify_code
    email = pending_login_email
    user  = email.present? ? User.authenticate_login_code(email: email, code: params[:code].to_s) : nil

    if user
      trial = PendingTrial.take(session)
      destination = start_new_session_for(user)
      return finish_pending_trial(user, trial) if trial

      redirect_to destination || root_path, notice: t("sessions.welcome_back", name: user.name)
    else
      @code_rejected = true
      # With no pending state the page renders no code field, so the message can't tell everyone to retry.
      flash.now[:alert] =
        email.present? ? t("sessions.code_rejected_retry") : t("sessions.code_rejected_request_new")
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    reset_session
    redirect_to login_path, notice: t("sessions.logged_out")
  end

  private

  def finish_pending_trial(user, trial)
    case trial.start_for(user)
    when :started     then redirect_to root_path, notice: t("trials.started")
    when :has_own_key then redirect_to setup_path, alert: t("trials.has_own_key")
    else                   redirect_to trial_path, alert: t("trials.code_rejected")
    end
  end

  def login_code_requests_limited(message) = rate_limited(message)

  # A bare 429 would strand the user; this keeps them on the page that can request a new code.
  def rate_limited(message)
    flash.now[:alert] = message
    render :new, status: :too_many_requests
  end

  # Single authority for "is a login pending in this browser"; a stamped state expires with its code.
  def pending_login_email
    return nil if pending_login_expired?

    session[:pending_login_email].presence
  end

  # An unreadable stamp counts as still pending: a stale banner is cheaper than rejecting a live code after a deploy.
  def pending_login_expired?
    stamped_at = session[:pending_login_at]
    return false if stamped_at.blank?

    Time.iso8601(stamped_at.to_s) < User::LOGIN_CODE_EXPIRY.ago
  rescue ArgumentError
    false
  end

  # Read return_to before reset_session, which discards everything written before authentication.
  def start_new_session_for(user)
    destination = session[:return_to]
    reset_session
    session[:user_id] = user.id
    destination
  end
end
