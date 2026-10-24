class SecondFactorChallengesController < ApplicationController
  include SignInCompletion

  skip_before_action :require_login
  skip_before_action :require_provider

  RATE_LIMIT_STORE = LazyCacheStore.new

  rate_limit to: 10, within: User::LOGIN_RATE_LIMIT_WINDOW,
             by:    -> { pending_second_factor["user_id"] || request.remote_ip },
             with:  -> { rate_limited },
             store: RATE_LIMIT_STORE,
             name:  "second_factor_attempts_for_account",
             only:  :create

  rate_limit to: 20, within: User::LOGIN_RATE_LIMIT_WINDOW,
             with:  -> { rate_limited },
             store: RATE_LIMIT_STORE,
             name:  "second_factor_attempts",
             only:  :create

  before_action :require_open_challenge

  # GET /login/second-factor
  def new
  end

  # POST /login/second-factor
  def create
    checked_at = Time.current
    outcome = @user.answer_second_factor_challenge!(params[:otp_code], issued_at: pending_second_factor["at"]) do
      remember_sign_in(@user, second_factor_proof, checked_at)
    end
    case outcome.status
    when :totp            then complete_sign_in(@user, checked_at: checked_at, factor: :authenticator)
    when :recovery_code   then complete_sign_in_with_recovery_code(outcome.remaining, checked_at)
    when :rejected        then render_new(t("second_factor_challenges.rejected"), :unprocessable_content)
    when :locked          then lock_out(outcome.retry_at)
    when :challenge_ended then end_challenge(t("second_factor_challenges.too_many_wrong_codes"))
    when :expired         then complete_repeated_sign_in || end_challenge(t("second_factor_challenges.expired"))
    else raise ArgumentError, "unhandled second-factor outcome: #{outcome.status}"
    end
  end

  private

  def require_open_challenge
    @user = User.active.find_by(id: pending_second_factor["user_id"])
    return if @user&.second_factor_challenge_open?(pending_second_factor["at"])
    return if request.post? && complete_repeated_sign_in

    end_challenge(t("second_factor_challenges.expired"))
  end

  def second_factor_proof = [ pending_second_factor["user_id"], pending_second_factor["at"], params[:otp_code].to_s ]

  def complete_repeated_sign_in
    checked_at = recent_sign_in(@user, second_factor_proof)&.dig(:checked_at) or return false

    PendingTrial.forget(session)
    complete_sign_in(@user, checked_at: checked_at, factor: :authenticator)
    true
  end

  def complete_sign_in_with_recovery_code(remaining, checked_at)
    complete_sign_in(@user, checked_at: checked_at, factor: :authenticator)
    flash[:notice] = t("second_factor_challenges.recovery_code_used", count: remaining)
  end

  def lock_out(retry_at)
    session.delete(PENDING_SECOND_FACTOR)
    @locked = true
    render_new(second_factor_cap_message(@user, retry_at), :too_many_requests)
  end

  def end_challenge(message)
    session.delete(PENDING_SECOND_FACTOR)
    redirect_to login_path, alert: message
  end

  def rate_limited
    render_new(t("sessions.rate_limited.code_attempts"), :too_many_requests)
  end

  def render_new(message, status)
    flash.now[:alert] = message
    render :new, status: status
  end
end
