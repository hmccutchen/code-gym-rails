# Rails reads these keys only from credentials, so without this wiring the first encryption raises at runtime.
Rails.application.configure do
  if ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present?
    config.active_record.encryption.primary_key         = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key   = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
  elsif Rails.env.development?
    # Dev-only keys derived from secret_key_base, so bin/dev works with no encryption env vars.
    base = Rails.application.secret_key_base
    config.active_record.encryption.primary_key         = base[0, 32]
    config.active_record.encryption.deterministic_key   = base[32, 32]
    config.active_record.encryption.key_derivation_salt = base[64, 32]
  end
end
