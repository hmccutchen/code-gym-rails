class SessionsController < ApplicationController
  skip_before_action :require_login
  skip_before_action :require_api_key

  # GET /login
  def new
    redirect_to root_path if logged_in?
  end

  # POST /login — send magic link (and its login-code twin)
  def create
    email = params[:email].to_s.strip.downcase
    name  = params[:name].to_s.strip

    # `active` only: an anonymized row's email was rewritten anyway, so this
    # falls through to account creation and the person gets a fresh account.
    user = User.active.find_by(email: email)

    if user.nil?
      user = User.create!(email: email, name: name.presence || email.split("@").first)
    end

    raw_token = user.generate_login_token!
    UserMailer.magic_link(user, raw_token, user.raw_login_code).deliver_later

    # Drives the "check your email" pending state on the login page (Fix 1's
    # code field, Fix 2's polling) across reloads in this same browser.
    session[:pending_login_email] = email

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
    session[:user_id] = user.id
    session.delete(:pending_login_email)

    redirect_to session.delete(:return_to) || root_path, notice: "Welcome back, #{user.name}!"
  end

  # POST /login/code — the PWA-friendly alternate to clicking the link.
  # Email comes from this browser's own pending-login session state, never
  # from a client-supplied field, so the code can't be used to target a
  # different account than the one that requested it here.
  def verify_code
    email = session[:pending_login_email]
    user  = email.present? ? User.authenticate_login_code(email: email, code: params[:code].to_s) : nil

    if user
      session[:user_id] = user.id
      session.delete(:pending_login_email)
      redirect_to session.delete(:return_to) || root_path, notice: "Welcome back, #{user.name}!"
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
    session.delete(:user_id)
    redirect_to login_path, notice: "Logged out."
  end
end
