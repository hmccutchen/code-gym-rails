require "active_support/core_ext/integer/time"
require_relative "../../lib/boot/app_host"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
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

  # Resend's HTTP API, because Railway blocks outbound SMTP below Pro (docs/deploy/railway-smtp-setup.md).
  config.action_mailer.delivery_method = :resend

  # Fall back to I18n.default_locale when a translation is missing.
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]
end
