Rails.application.configure do
  config.enable_reloading = false
  # Eager load on CI so a broken eager load fails there before deploy.
  config.eager_load = ENV["CI"].present?
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
  config.active_storage.service = :test
  config.action_mailer.delivery_method = :test
  config.action_mailer.default_url_options = { host: "example.com" }
  # rspec-rails' have_enqueued_* matchers require the :test adapter.
  config.active_job.queue_adapter = :test

  # Throwaway keys so `encrypts :api_keys` works without real credentials.
  config.active_record.encryption.primary_key = "test" * 8
  config.active_record.encryption.deterministic_key = "test" * 8
  config.active_record.encryption.key_derivation_salt = "test" * 8

  config.active_support.deprecation = :stderr
  config.i18n.raise_on_missing_translations = true
  config.action_controller.raise_on_missing_callback_actions = true
end
