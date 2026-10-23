# Design notes: docs/code-notes/app/controllers/concerns/authenticator_changes.md
module AuthenticatorChanges
  extend ActiveSupport::Concern

  RATE_LIMIT_STORE = LazyCacheStore.new
  SCOPE = "authenticator_changes"

  class_methods do
    def limit_authenticator_changes(only:)
      rate_limit to: 10, within: User::LOGIN_RATE_LIMIT_WINDOW, by: -> { current_user.id },
                 with: -> { redirect_to account_path, alert: t("authenticators.rate_limited") },
                 store: RATE_LIMIT_STORE, scope: SCOPE, name: "authenticator_changes", only: only
    end
  end

  private

  def forbid_caching
    response.headers["Cache-Control"] = "no-store"
  end

  def notify_second_factor_change(change)
    UserMailer.second_factor_changed(current_user, change.to_s, Time.current).deliver_later
  end

  def daily_cap_message(retry_at)
    t("second_factor_challenges.locked", time: l(retry_at.in_time_zone(current_user.effective_time_zone), format: :long))
  end

  def show_recovery_codes(codes, notice)
    forbid_caching
    @recovery_codes = codes
    flash.now[:notice] = notice
    render "recovery_codes/show"
  end
end
