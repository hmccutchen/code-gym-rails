class SessionsController < ApplicationController
  include LoginCodeRequests

  skip_before_action :require_login
  skip_before_action :require_provider

  helper_method :pending_login_email

  RATE_LIMIT_STORE = LazyCacheStore.new

  limit_login_code_requests only: :create

  # Every limit here needs a distinct `name:`: Rails keys a limit on
  # ["rate-limit", scope, name, by].compact.join(":") and scope defaults to the
  # controller. The request limits above live in their own scope, so a
  # `POST /login` with a chosen IP as the email cannot lock that IP out of
  # #verify_code.
  rate_limit to: 10, within: User::LOGIN_CODE_EXPIRY,
             with:  -> { rate_limited(t("sessions.rate_limited.code_attempts")) },
             store: RATE_LIMIT_STORE,
             name:  "code_attempts",
             only:  :verify_code

  # The IP limit on attempts does not hold against rotating IPs: each can
  # request a fresh code for the same address and spend its five guesses.
  # Keyed on the address this browser is logging in to, so guesses at one
  # account are capped wherever they come from. Anyone can start a login for
  # any address, so this also lets someone lock an address out of guessing
  # for an hour; a shorter window keeps that short. With no login pending the
  # attempt fails anyway, and the IP keeps those out of one shared bucket.
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

  # POST /login — mail a 6-digit code. It is redeemable only in the browser
  # that requested it (see #verify_code), so the pending state written here is
  # what makes the code usable at all, not merely a UI convenience.
  # Asking for a plain login code drops a trial asked for earlier in this
  # browser, so a later sign-in never starts one by surprise.
  def create
    PendingTrial.forget(session)
    mail_login_code(normalized_email, params[:name].to_s.strip)

    redirect_to login_path,
                notice: t("sessions.code_sent", expiry: User.login_code_expiry_in_words)
  rescue ActiveRecord::RecordInvalid
    flash.now[:alert] = t("sessions.email_not_accepted")
    render :new, status: :unprocessable_content
  end

  # POST /login/code — the only way in. Email comes from this browser's own
  # pending-login session state, never from a client-supplied field, so the
  # code can't be used to target a different account than the one that
  # requested it here.
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
      # No pending state renders no code field to try again in — see
      # new.html.erb's gate on pending_login_email — so the message can't
      # tell everyone to retry.
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

  # The emailed code proved the address, so the trial asked for on the trial
  # page can take its seat now.
  def finish_pending_trial(user, trial)
    case trial.start_for(user)
    when :started     then redirect_to root_path, notice: t("trials.started")
    when :has_own_key then redirect_to setup_path, alert: t("trials.has_own_key")
    else                   redirect_to trial_path, alert: t("trials.code_rejected")
    end
  end

  def login_code_requests_limited(message) = rate_limited(message)

  # A bare 429 would drop someone out of the flow with no way back; this keeps
  # them on the page that can request a new code.
  def rate_limited(message)
    flash.now[:alert] = message
    render :new, status: :too_many_requests
  end

  # The single authority for "is a login pending in this browser," read by
  # both #verify_code and the login page. A stamped state expires with the
  # code it describes — the pending state is only ever a claim that a live
  # code is in someone's inbox, and a stale claim used to leave the login
  # page insisting on an email that could no longer log anyone in. A state
  # carrying no readable stamp is the one exception, and stays pending for the
  # life of the cookie; see #pending_login_expired? for why that is the safer
  # side to err on.
  def pending_login_email
    return nil if pending_login_expired?

    session[:pending_login_email].presence
  end

  # A stamp this can't read is one a different version of this app wrote — the
  # session cookie is signed and encrypted, so a hand-edited value never gets
  # this far. Both unreadable cases resolve toward still-pending rather than
  # expired, which is deliberate but asymmetric, so the two costs:
  #
  #   pending  — a session that predates the stamp shows a stale banner until
  #              its cookie lapses, up to two days. Cosmetic: the email form
  #              renders alongside it, so nothing is trapped.
  #   expired  — an in-flight login started before this shipped has its still
  #              live code rejected as "incorrect or expired" for the 15
  #              minutes after a deploy. A real failure, not a cosmetic one.
  #
  # Both land on the same population — sessions created before this shipped —
  # so the choice is only which way they fail, and a stale banner beats a
  # rejected working code.
  def pending_login_expired?
    stamped_at = session[:pending_login_at]
    return false if stamped_at.blank?

    Time.iso8601(stamped_at.to_s) < User::LOGIN_CODE_EXPIRY.ago
  rescue ArgumentError
    false
  end

  # Rotate the session on login so nothing written before authentication —
  # return_to, the pending-login state — survives into the authenticated
  # session. Returns the pre-login return_to, which has to be read out before
  # reset_session discards it.
  def start_new_session_for(user)
    destination = session[:return_to]
    reset_session
    session[:user_id] = user.id
    destination
  end
end
