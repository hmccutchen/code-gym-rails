class RecoveryCodesController < ApplicationController
  include AuthenticatorChanges

  skip_before_action :require_provider

  limit_authenticator_changes only: :create

  def create
    outcome = current_user.regenerate_recovery_codes!(params[:otp_code])
    case outcome.status
    when :regenerated then regenerated(outcome.recovery_codes)
    when :rejected    then redirect_to account_path, alert: t("authenticators.code_rejected")
    when :locked      then redirect_to account_path, alert: daily_cap_message(outcome.retry_at)
    else raise ArgumentError, "unhandled recovery code outcome: #{outcome.status}"
    end
  end

  private

  def regenerated(codes)
    notify_second_factor_change(:recovery_codes)
    show_recovery_codes(codes, t("recovery_codes.regenerated"))
  end
end
