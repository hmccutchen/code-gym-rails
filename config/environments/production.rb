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

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

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

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # Solid Queue runs against the primary database (no connects_to override):
  # Railway provides a single postgres, and the solid_* tables live there.
  config.active_job.queue_adapter = :solid_queue

  # Raise delivery errors so failed sends surface as failed/retried Solid Queue jobs
  # (UserMailer.login_code is sent via deliver_later) instead of failing silently.
  config.action_mailer.raise_delivery_errors = true

  # Set host to be used by links generated in mailer templates (e.g. the magic link
  # verify_auth_url). Mailer views render outside the request cycle, so config.force_ssl
  # has no effect here -- protocol is forced to https explicitly.
  app_host = AppHost.resolve
  config.action_mailer.default_url_options = { host: app_host, protocol: "https" }

  # Allow the app's own origin to open ActionCable WebSocket connections.
  # Nothing subscribes today -- this layout loads no Turbo or Stimulus, and the
  # dashboard learns a generation finished by polling /dashboard/status -- so
  # this is the standing allowance for the mounted cable, not the transport any
  # current feature runs on. Derived from the same resolved host as the mailer
  # config above. Browser Origin headers always include the scheme, so only the
  # full "https://host" form is ever matched.
  config.action_cable.allowed_request_origins = [ "https://#{app_host}" ]

  # Deliver via Resend's HTTP API (see docs/deploy/railway-smtp-setup.md).
  # Railway blocks outbound SMTP on plans below Pro, so smtp_settings would
  # time out at TCP connect -- the API key is set in config/initializers/resend.rb.
  config.action_mailer.delivery_method = :resend

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
