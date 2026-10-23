# Every push surface checks #configured?, so an unconfigured deployment offers nothing; keys: docs/deploy/web-push-setup.md.
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

  # RFC 8292 "sub" claim; falls back to MAIL_FROM so a configured mailer needs no extra variable.
  def self.subject
    ENV[SUBJECT_VAR].to_s.strip.presence || "mailto:#{ENV.fetch('MAIL_FROM', 'from@example.com')}"
  end
end
