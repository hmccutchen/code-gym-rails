class SessionsController < ApplicationController
  skip_before_action :require_login
  skip_before_action :require_api_key

  # GET /login
  def new
    redirect_to root_path if logged_in?
  end

  # POST /login — send magic link
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
    UserMailer.magic_link(user, raw_token).deliver_later

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

    redirect_to session.delete(:return_to) || root_path, notice: "Welcome back, #{user.name}!"
  end

  def destroy
    session.delete(:user_id)
    redirect_to login_path, notice: "Logged out."
  end
end
