# Design notes: docs/code-notes/app/controllers/two_factor_setups_controller.md
class TwoFactorSetupsController < ApplicationController
  skip_before_action :require_two_factor, :require_provider
  before_action :require_not_enrolled

  RATE_LIMIT_STORE = LazyCacheStore.new

  rate_limit to: 10, within: 15.minutes, by: -> { current_user.id }, with: -> { attempts_limited },
             store: RATE_LIMIT_STORE, name: "enrollment_attempts", only: :create

  # GET /two_factor_setup
  def show
    @secret = current_user.prepare_two_factor_secret!
  end

  # POST /two_factor_setup — the backup codes exist only in this reply, so it renders rather than redirects.
  def create
    @backup_codes = current_user.enroll_two_factor!(params[:code].to_s)
    return render(:backup_codes) if @backup_codes
    return redirect_to(account_path, notice: t("two_factor_setups.already_on")) if current_user.two_factor_enrolled?

    @secret = current_user.otp_secret
    flash.now[:alert] = t("two_factor_setups.code_rejected")
    render :show, status: :unprocessable_content
  end

  private

  def require_not_enrolled
    redirect_to root_path if current_user.two_factor_enrolled?
  end

  def attempts_limited
    @secret = current_user.otp_secret
    flash.now[:alert] = t("two_factor_setups.rate_limited")
    render :show, status: :too_many_requests
  end
end
