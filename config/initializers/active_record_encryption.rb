# ActiveRecord Encryption keys for `encrypts :api_key` on User.
#
# Rails only reads these from encrypted credentials by default; this app
# supplies them via env vars instead (set on the Railway services). Without
# this wiring, the first attempted encryption raises
# ActiveRecord::Encryption::Errors::Configuration at runtime.
# Test keys live in config/environments/test.rb.
Rails.application.configure do
  if ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present?
    config.active_record.encryption.primary_key         = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key   = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
  elsif Rails.env.development?
    # Derive stable dev-only keys from secret_key_base so `bin/dev` works with
    # no encryption env vars configured. Never used in production.
    base = Rails.application.secret_key_base
    config.active_record.encryption.primary_key         = base[0, 32]
    config.active_record.encryption.deterministic_key   = base[32, 32]
    config.active_record.encryption.key_derivation_salt = base[64, 32]
  end
end
