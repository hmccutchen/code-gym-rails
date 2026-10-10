require "active_support/core_ext/integer/time"
require_relative "../../lib/boot/app_host"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }
  config.active_storage.service = :local
  config.assume_ssl = true
  config.force_ssl = true

  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)
  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false

  config.cache_store = :solid_cache_store
  # Solid Queue uses the primary database: Railway provides one postgres, which holds the solid_* tables.
  config.active_job.queue_adapter = :solid_queue

  # Raise so a failed send becomes a failed, retried Solid Queue job instead of vanishing.
  config.action_mailer.raise_delivery_errors = true
  # Mailer views render outside the request cycle, where force_ssl has no effect, so https is set here.
  app_host = AppHost.resolve
  config.action_mailer.default_url_options = { host: app_host, protocol: "https" }
  # Browser Origin headers include the scheme, so only the full https:// form matches.
  config.action_cable.allowed_request_origins = [ "https://#{app_host}" ]
  config.action_mailer.delivery_method = :resend

  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]
end
