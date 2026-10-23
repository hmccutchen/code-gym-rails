class BackupCodesController < ApplicationController
  skip_before_action :require_provider

  RATE_LIMIT_STORE = LazyCacheStore.new

  rate_limit to: 10, within: 15.minutes, by: -> { current_user.id }, with: -> { attempts_limited },
             store: RATE_LIMIT_STORE, name: "backup_code_regenerations", only: :create

  # POST /backup_codes — a second-factor code is required, so an open session alone cannot take the codes.
  def create
    outcome = current_user.regenerate_backup_codes!(params[:code].to_s)
    case outcome.status
    when :regenerated
      @backup_codes = outcome.backup_codes
      render "two_factor_setups/backup_codes"
    when :rejected then redirect_to account_path, alert: t("backup_codes.code_rejected")
    else raise ArgumentError, "unhandled backup code outcome #{outcome.status}"
    end
  end

  private

  def attempts_limited
    redirect_to account_path, alert: t("backup_codes.rate_limited")
  end
end
