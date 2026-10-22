# Design notes: docs/code-notes/config/initializers/devise.md
Devise.otp_allowed_drift = 30

Devise.setup do |config|
  require "devise/orm/active_record"

  config.mailer_sender = ENV.fetch("MAIL_FROM", "from@example.com")
  config.parent_mailer = "ApplicationMailer"

  config.case_insensitive_keys = [ :email ]
  config.strip_whitespace_keys = [ :email ]
  config.skip_session_storage  = [ :http_auth ]
  config.paranoid              = true
  config.stretches             = Rails.env.test? ? 1 : 12

  config.password_length        = 12..128
  config.reconfirmable          = false
  config.confirm_within         = 3.days
  config.reset_password_within  = 2.hours
  # A reset must not sign in: the authenticator code would be skipped.
  config.sign_in_after_reset_password = false
  config.sign_out_via = :delete

  # JSON gets the login redirect too: request.js reads that redirect as an expired session.
  config.navigational_formats = [ "*/*", :html, :turbo_stream, :json ]

  config.responder.error_status    = :unprocessable_content
  config.responder.redirect_status = :see_other

  config.warden do |manager|
    manager.failure_app = ->(env) { SignInFailureApp.call(env) }
    manager.default_strategies(scope: :user).unshift :two_factor_backupable
  end
end
