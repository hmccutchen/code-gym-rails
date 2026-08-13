class SessionsController < ApplicationController
  skip_before_action :require_login
  skip_before_action :require_api_key

  # GET /login
  def new
    redirect_to root_path if logged_in?
  end

  # POST /login — send magic link, plus its login-code twin only when the
  # request came from a touch device. The code is redeemable solely in the
  # browser that requested it (see #verify_code), so mailing one to a desktop
  # requester would be noise they could never act on.
  # See docs/superpowers/plans/2026-08-03-touch-device-gated-login-code.md
  def create
    email = params[:email].to_s.strip.downcase
    name  = params[:name].to_s.strip
    touch_device = params[:touch_device] == "1"

    # `active` only: an anonymized row's email was rewritten anyway, so this
    # falls through to account creation and the person gets a fresh account.
    user = User.active.find_by(email: email)

    if user.nil?
      user = User.create!(email: email, name: name.presence || email.split("@").first)
    end

    raw_token = user.generate_login_token!
    UserMailer.magic_link(user, raw_token, touch_device ? user.raw_login_code : nil).deliver_later

    # Drives the "check your email" pending state on the login page (the code
    # field, the polling) across reloads in this same browser.
    session[:pending_login_email] = email
    session[:pending_login_touch] = touch_device

    redirect_to login_path, notice: "Check your email for a login link. It expires in 15 minutes."
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  # GET /auth/verify?token=...
  def verify
    user = User.find_by_login_token(params[:token].to_s)

    if user.nil?
      redirect_to login_path, alert: "That link is invalid or expired. Try again."
      return
    end

    user.clear_login_token!
    destination = start_new_session_for(user)

    redirect_to destination || root_path, notice: "Welcome back, #{user.name}!"
  end

  # POST /login/code — the PWA-friendly alternate to clicking the link.
  # Email comes from this browser's own pending-login session state, never
  # from a client-supplied field, so the code can't be used to target a
  # different account than the one that requested it here.
  def verify_code
    email = session[:pending_login_email]
    user  = email.present? ? User.authenticate_login_code(email: email, code: params[:code].to_s) : nil

    if user
      destination = start_new_session_for(user)
      redirect_to destination || root_path, notice: "Welcome back, #{user.name}!"
    else
      flash.now[:alert] = "Incorrect or expired code. Try again, or use the link in your email."
      render :new, status: :unprocessable_entity
    end
  end

  # GET /login/status — polled by the pending-login state in a normal
  # (non-PWA) browser tab. Relies on Rails' cookie session store sharing one
  # cookie across tabs in the same browser: once the tab that clicked the
  # link sets session[:user_id], this tab's very next request already
  # carries the updated cookie.
  def status
    render json: { authenticated: logged_in? }
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "Logged out."
  end

  private

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
