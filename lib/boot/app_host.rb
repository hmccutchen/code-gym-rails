require "uri"

# The host this app's generated URLs point at — the mailer's magic links and
# ActionCable's allowed origin.
#
# Two sources, in priority order, because they mean different things. APP_HOST
# is set deliberately (production's custom domain) and must win.
# RAILWAY_PUBLIC_DOMAIN is injected by Railway into every environment including
# production, so preferring it would silently override that deliberate choice
# the moment the two disagree.
#
# Neither is assumed to carry a scheme. Railway injects a bare host
# ("web-….up.railway.app"), and URI.parse returns a nil #host for one — which
# is what left every preview app with default_url_options[:host] = nil and no
# working magic link.
#
# Lives outside the autoload path on purpose: config/environments/production.rb
# runs during Rails.application.configure, and autoloading there raises. See
# config.autoload_lib's ignore list in config/application.rb.
module AppHost
  FALLBACK = "example.com".freeze

  SOURCES = %w[APP_HOST RAILWAY_PUBLIC_DOMAIN].freeze

  def self.resolve(env = ENV)
    SOURCES.filter_map { |name| host_from(env[name]) }.first || FALLBACK
  end

  # Parsed with a scheme forced on, so a bare host and a full URL take the same
  # path instead of one of them returning nil.
  def self.host_from(value)
    text = value.to_s.strip
    return if text.empty?

    URI.parse(text.include?("//") ? text : "https://#{text}").host
  rescue URI::InvalidURIError
    nil
  end
  private_class_method :host_from
end
