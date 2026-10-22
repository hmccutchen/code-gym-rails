class AuthenticatorMovesController < ApplicationController
  skip_before_action :require_provider

  RATE_LIMIT_STORE = LazyCacheStore.new

  rate_limit to: 10, within: 15.minutes, by: -> { current_user.id }, with: -> { attempts_limited },
             store: RATE_LIMIT_STORE, name: "authenticator_moves", only: :create

  # POST /authenticator_move — a second-factor code turns the authenticator off, and setup then shows a new QR code.
  def create
    outcome = current_user.release_authenticator!(params[:code].to_s)
    case outcome.status
    when :released then redirect_to two_factor_setup_path, notice: t("authenticator_moves.released")
    when :rejected then redirect_to account_path, alert: t("authenticator_moves.code_rejected")
    else raise ArgumentError, "unhandled authenticator move outcome #{outcome.status}"
    end
  end

  private

  def attempts_limited
    redirect_to account_path, alert: t("backup_codes.rate_limited")
  end
end
