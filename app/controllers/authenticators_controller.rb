class AuthenticatorsController < ApplicationController
  include AuthenticatorChanges

  skip_before_action :require_provider
  before_action :forbid_caching, only: %i[show create]
  before_action :redirect_when_enabled, only: :show
  before_action :require_recent_sign_in, only: %i[show create]

  limit_authenticator_changes only: %i[create destroy]

  PENDING_SECRET = :pending_otp_secret

  def show
    @secret = pending_secret
  end

  def create
    outcome = current_user.enable_second_factor!(params[:otp_code], secret: session[PENDING_SECRET])
    case outcome.status
    when :enabled    then finish_change(outcome, :enabled) { enabled(outcome.recovery_codes) }
    when :already_on then redirect_to account_path, notice: t("authenticators.already_on")
    when :rejected   then reject_setup_code
    else raise ArgumentError, "unhandled authenticator outcome: #{outcome.status}"
    end
  end

  def destroy
    outcome = current_user.disable_second_factor!(params[:otp_code])
    case outcome.status
    when :disabled    then finish_change(outcome, :disabled) { redirect_to account_path, notice: t("authenticators.disabled") }
    when :already_off then redirect_to account_path
    when :rejected    then redirect_to account_path, alert: t("authenticators.code_rejected")
    when :locked      then redirect_to account_path, alert: second_factor_cap_message(current_user, outcome.retry_at)
    else raise ArgumentError, "unhandled authenticator outcome: #{outcome.status}"
    end
  end

  # DELETE /account/authenticator/sign_in_again
  def sign_in_again
    reset_session
    session[:return_to] = account_authenticator_path
    redirect_to login_path, notice: t("authenticators.sign_in_again.notice")
  end

  private

  def redirect_when_enabled
    redirect_to account_path, notice: t("authenticators.already_on") if current_user.two_factor_enabled?
  end

  def require_recent_sign_in
    render :sign_in_again, status: request.get? ? :ok : :forbidden unless User.signed_in_recently?(session[:signed_in_at])
  end

  # Per session, so a key read in one session, an intruder's included, is never the key another session enrolls.
  def pending_secret
    session[PENDING_SECRET] ||= User.new_second_factor_secret
  end

  def enabled(recovery_codes)
    session.delete(PENDING_SECRET)
    show_recovery_codes(recovery_codes, t("authenticators.enabled"))
  end

  def finish_change(outcome, change)
    session[:signed_in_at] = User.session_stamp(outcome.changed_at)
    notify_second_factor_change(change, outcome.changed_at)
    yield
  end

  def reject_setup_code
    @secret = pending_secret
    flash.now[:alert] = t("authenticators.code_rejected")
    render :show, status: :unprocessable_content
  end
end
