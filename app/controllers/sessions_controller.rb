class SessionsController < ApplicationController
  skip_before_action :require_login
  skip_before_action :require_api_key

  helper_method :pending_login_email

  RATE_LIMIT_STORE = LazyCacheStore.new

  # Capping requests per address is the one that matters: a fresh code resets
  # login_code_attempts, so uncapped re-requests would turn the five-guess
  # ceiling into five guesses per request, forever. Keyed on the address
  # rather than the IP because the address is what an attacker targets and
  # the IP is what they can change.
  #
  # All three limits need distinct `name:`s: Rails keys a limit on
  # ["rate-limit", scope, name, by].compact.join(":"), scope defaults to the
  # controller, and `by` for #create is attacker-controlled (any email an
  # attacker submits) — unnamed, they would collide into one bucket, letting a
  # `POST /login` with a chosen IP as the email lock that IP out of
  # #verify_code.
  rate_limit to: 5, within: User::LOGIN_CODE_EXPIRY,
             by:    -> { normalized_email },
             with:  -> { rate_limited("Too many code requests for that address. Try again in a few minutes.") },
             store: RATE_LIMIT_STORE,
             name:  "code_requests",
             only:  :create

  rate_limit to: 10, within: User::LOGIN_CODE_EXPIRY,
             with:  -> { rate_limited("Too many attempts. Try again in a few minutes.") },
             store: RATE_LIMIT_STORE,
             name:  "code_attempts",
             only:  :verify_code

  # The address-keyed limit above can't bound an attacker who varies the
  # address on every request — and an unrecognized address creates an
  # account and sends real mail, so unbounded #create is unbounded outbound
  # mail from a public, internet-reachable page. `by:` defaults to
  # request.remote_ip, which is the axis that matters here.
  rate_limit to: 20, within: User::LOGIN_CODE_EXPIRY,
             with:  -> { rate_limited("Too many code requests. Try again in a few minutes.") },
             store: RATE_LIMIT_STORE,
             name:  "code_requests_by_ip",
             only:  :create

  # GET /login
  def new
    redirect_to root_path if logged_in?
  end

  # POST /login — mail a 6-digit code. It is redeemable only in the browser
  # that requested it (see #verify_code), so the pending state written here is
  # what makes the code usable at all, not merely a UI convenience.
  def create
    email = normalized_email
    name  = params[:name].to_s.strip

    # `active` only: an anonymized row's email was rewritten anyway, so this
    # falls through to account creation and the person gets a fresh account.
    user = User.active.find_by(email: email)

    if user.nil?
      user = User.create!(email: email, name: name.presence || email.split("@").first)
    end

    UserMailer.login_code(user, user.generate_login_code!).deliver_later

    # Drives the code form on the login page across reloads in this same
    # browser. Stamped so the state can age out with the code it describes —
    # see #pending_login_email.
    session[:pending_login_email] = email
    session[:pending_login_at]    = Time.current.iso8601

    redirect_to login_path, notice: "Check your email for a 6-digit login code. It expires in 15 minutes."
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  # POST /login/code — the only way in. Email comes from this browser's own
  # pending-login session state, never from a client-supplied field, so the
  # code can't be used to target a different account than the one that
  # requested it here.
  def verify_code
    email = pending_login_email
    user  = email.present? ? User.authenticate_login_code(email: email, code: params[:code].to_s) : nil

    if user
      destination = start_new_session_for(user)
      redirect_to destination || root_path, notice: "Welcome back, #{user.name}!"
    else
      # No pending state renders no code field to try again in — see
      # new.html.erb's gate on pending_login_email — so the message can't
      # tell everyone to retry.
      flash.now[:alert] =
        if email.present?
          "Incorrect or expired code. Try again, or request a new one below."
        else
          "Incorrect or expired code. Request a new one below."
        end
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "Logged out."
  end

  private

  # The single normalization rule for a submitted email, so the #create
  # rate limit's `by:` lambda (instance_exec'd here, so it can call a
  # private method) and #create itself can never drift apart.
  def normalized_email
    params[:email].to_s.strip.downcase
  end

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
