# The VAPID keypair the daily reminder is signed with, and the single authority
# for "is web push configured here at all."
#
# Every surface derives from #configured?: the Account toggle renders only when
# it's true, the layout's re-subscribe script is emitted only when it's true,
# PushSubscriptionsController refuses when it's false, and SendPushReminderJob
# returns without contacting a push service. That keeps an unconfigured
# deployment — a fresh checkout, a preview app, CI — from offering a control
# that could only fail, rather than each surface deciding for itself.
#
# ENV rather than credentials, matching how the other deployed secrets here
# (RESEND_API_KEY, the ACTIVE_RECORD_ENCRYPTION_* keys) are wired on Railway.
# Generate a pair with:
#
#   bin/rails runner 'require "web_push"; pp WebPush.generate_key.then { |k| { public: k.public_key, private: k.private_key } }'
module WebPushCredentials
  PUBLIC_KEY_VAR  = "VAPID_PUBLIC_KEY".freeze
  PRIVATE_KEY_VAR = "VAPID_PRIVATE_KEY".freeze
  SUBJECT_VAR     = "VAPID_SUBJECT".freeze

  def self.configured?
    public_key.present? && private_key.present?
  end

  def self.public_key
    ENV[PUBLIC_KEY_VAR].to_s.strip.presence
  end

  def self.private_key
    ENV[PRIVATE_KEY_VAR].to_s.strip.presence
  end

  # The RFC 8292 "sub" claim: how a push service reaches whoever operates this
  # deployment. Falls back to the address the app already sends mail from, so a
  # correctly configured mailer means one less variable to set.
  def self.subject
    ENV[SUBJECT_VAR].to_s.strip.presence || "mailto:#{ENV.fetch('MAIL_FROM', 'from@example.com')}"
  end
end
