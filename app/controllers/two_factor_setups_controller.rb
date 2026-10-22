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
    outcome = current_user.enroll_two_factor!(params[:code].to_s)
    case outcome.status
    when :enrolled
      @backup_codes = outcome.backup_codes
      render :backup_codes
    when :already_on then redirect_to account_path, notice: t("two_factor_setups.already_on")
    when :rejected then refuse(t("two_factor_setups.code_rejected"), :unprocessable_content)
    else raise ArgumentError, "unhandled enrollment outcome #{outcome.status}"
    end
  end

  private

  def require_not_enrolled
    redirect_to root_path if current_user.two_factor_enrolled?
  end

  def attempts_limited = refuse(t("two_factor_setups.rate_limited"), :too_many_requests)

  def refuse(message, status)
    @secret = current_user.otp_secret
    flash.now[:alert] = message
    render :show, status: status
  end
end
