# Shared by the login and trial forms, which count against the same limits so a second form is no second allowance.
module LoginCodeRequests
  extend ActiveSupport::Concern

  RATE_LIMIT_STORE = LazyCacheStore.new
  SCOPE = "login_code_requests"

  class_methods do
    # Per-address caps stop fresh codes resetting the guess limit; IP caps bound mail; each needs a distinct `name:`.
    def limit_login_code_requests(only:)
      rate_limit to: 5, within: User::LOGIN_CODE_EXPIRY, by: -> { normalized_email },
                 with: -> { login_code_requests_limited(t("sessions.rate_limited.code_requests_for_address")) },
                 store: RATE_LIMIT_STORE, scope: SCOPE, name: "code_requests", only: only
      rate_limit to: 20, within: User::LOGIN_CODE_EXPIRY,
                 with: -> { login_code_requests_limited(t("sessions.rate_limited.code_requests")) },
                 store: RATE_LIMIT_STORE, scope: SCOPE, name: "code_requests_by_ip", only: only
      rate_limit to: 50, within: 1.day,
                 with: -> { login_code_requests_limited(t("sessions.rate_limited.code_requests")) },
                 store: RATE_LIMIT_STORE, scope: SCOPE, name: "code_requests_by_ip_daily", only: only
    end
  end

  private

  # The one normalization rule, so the address limit's `by:` and the request itself can't drift apart.
  def normalized_email
    params[:email].to_s.strip.downcase
  end

  # `active` only: an anonymized row's email was rewritten, so this creates a fresh account instead.
  def mail_login_code(email, name)
    user = User.active.find_by(email: email) ||
           User.create!(email: email, name: name.presence || email.split("@").first)
    UserMailer.login_code(user, user.generate_login_code!).deliver_later

    session[:pending_login_email] = email
    session[:pending_login_at]    = Time.current.iso8601
    user
  end
end
