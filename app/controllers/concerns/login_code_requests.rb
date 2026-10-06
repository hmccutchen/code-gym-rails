# Mailing a login code: the account it is for, the mail, the pending state
# this browser keeps, and the limits on asking. The login form and the trial
# form both mail one, and they count against the same limits, so a second
# form is not a second allowance.
module LoginCodeRequests
  extend ActiveSupport::Concern

  RATE_LIMIT_STORE = LazyCacheStore.new
  SCOPE = "login_code_requests"

  class_methods do
    # Capping requests per address is the one that matters: a fresh code
    # resets login_code_attempts, so uncapped re-requests would turn the
    # five-guess ceiling into five guesses per request, forever. Keyed on the
    # address rather than the IP because the address is what an attacker
    # targets and the IP is what they can change.
    #
    # The address limit can't bound an attacker who varies the address on
    # every request, and an unrecognized address creates an account and sends
    # real mail, so the IP limits bound outbound mail from a public page: 20
    # per code lifetime, and 50 a day, since the first alone still allows
    # about 1,900 a day.
    #
    # Each limit needs a distinct `name:`: Rails keys a limit on
    # ["rate-limit", scope, name, by].compact.join(":"), and `by` for the
    # address limit is attacker-controlled, so unnamed limits would collide.
    # The fixed scope is what shares the counts across both forms.
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

  # The single normalization rule for a submitted email, so the address
  # limit's `by:` lambda and the request itself can never drift apart.
  def normalized_email
    params[:email].to_s.strip.downcase
  end

  # `active` only: an anonymized row's email was rewritten anyway, so this
  # falls through to account creation and the person gets a fresh account.
  # The pending state drives the code form on the login page across reloads
  # in this browser, and is stamped so it ages out with the code.
  def mail_login_code(email, name)
    user = User.active.find_by(email: email) ||
           User.create!(email: email, name: name.presence || email.split("@").first)
    UserMailer.login_code(user, user.generate_login_code!).deliver_later

    session[:pending_login_email] = email
    session[:pending_login_at]    = Time.current.iso8601
    user
  end
end
