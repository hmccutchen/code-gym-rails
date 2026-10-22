# Design notes: docs/code-notes/app/controllers/first_sign_ins_controller.md
class FirstSignInsController < ApplicationController
  skip_before_action :authenticate_user!

  helper_method :pending_login_email

  RATE_LIMIT_STORE = LazyCacheStore.new

  rate_limit to: 5, within: User::LOGIN_CODE_EXPIRY, by: -> { normalized_email },
             with: -> { rate_limited(t("first_sign_ins.rate_limited.code_requests_for_address")) },
             store: RATE_LIMIT_STORE, name: "code_requests", only: :create
  rate_limit to: 20, within: User::LOGIN_CODE_EXPIRY,
             with: -> { rate_limited(t("first_sign_ins.rate_limited.code_requests")) },
             store: RATE_LIMIT_STORE, name: "code_requests_by_ip", only: :create
  rate_limit to: 10, within: User::LOGIN_CODE_EXPIRY,
             with: -> { rate_limited(t("first_sign_ins.rate_limited.code_attempts")) },
             store: RATE_LIMIT_STORE, name: "code_attempts", only: :verify_code
  rate_limit to: 10, within: 1.hour, by: -> { pending_login_email || request.remote_ip },
             with: -> { rate_limited(t("first_sign_ins.rate_limited.code_attempts")) },
             store: RATE_LIMIT_STORE, name: "code_attempts_for_address", only: :verify_code

  # GET /login/first
  def new
    redirect_to root_path if user_signed_in?
  end

  # POST /login/first — the same reply whether or not the address is waiting, so it reveals no accounts.
  def create
    user = User.awaiting_password.find_by(email: normalized_email)
    UserMailer.login_code(user, user.generate_login_code!).deliver_later if user

    session[:pending_login_email] = normalized_email
    session[:pending_login_at]    = Time.current.iso8601
    redirect_to first_sign_in_path, notice: t("first_sign_ins.code_sent", expiry: User.login_code_expiry_in_words)
  end

  # POST /login/first/code — the email comes from this browser's session, never a form field.
  def verify_code
    email = pending_login_email
    user  = email.present? ? User.authenticate_login_code(email: email, code: params[:code].to_s) : nil
    return reject_code(email) unless user

    session.delete(:pending_login_email)
    session.delete(:pending_login_at)
    sign_in(user)
    redirect_to edit_password_setup_path, notice: t("first_sign_ins.choose_password", name: user.name)
  end

  private

  def normalized_email
    params[:email].to_s.strip.downcase
  end

  def reject_code(email)
    @code_rejected = true
    flash.now[:alert] = email.present? ? t("first_sign_ins.code_rejected_retry") : t("first_sign_ins.code_rejected_request_new")
    render :new, status: :unprocessable_content
  end

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

    Time.iso8601(stamped_at.to_s) < User::LOGIN_CODE_EXPIRY.ago
  rescue ArgumentError
    false
  end
end
