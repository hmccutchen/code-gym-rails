require "uri"

# The host this app's generated URLs point at — default_url_options and
# ActionCable's allowed origin.
#
# Two sources, and which one wins depends on the environment, because they mean
# different things. APP_HOST is set deliberately (production's custom domain)
# and must beat an injected value there. RAILWAY_PUBLIC_DOMAIN is injected by
# Railway into every environment, production included, so preferring it
# everywhere would silently override that deliberate choice the moment the two
# disagree.
#
# A pull-request deployment inverts that, and not hypothetically: a PR
# environment inherits its base environment's service variables, so it arrives
# carrying production's APP_HOST. Honoring it there would point a preview app's
# default_url_options and ActionCable origin check at production's host instead
# of its own. On a preview app the injected domain is the only value that
# describes the app actually serving the request, so it wins.
#
# ENV is read directly rather than through PreviewEnvironment: this runs during
# Rails.application.configure, where autoloading raises, and one duplicated
# ENV.key? is a smaller cost than making the gate loadable at boot. The name is
# still owned by PreviewEnvironment::VAR — a spec asserts the two agree.
#
# Neither value is assumed to carry a scheme. Railway injects a bare host
# ("web-….up.railway.app"), and URI.parse returns a nil #host for one — which
# is what left every preview app with default_url_options[:host] = nil and a
# broken ActionCable origin check.
#
# Lives outside the autoload path on purpose: config/environments/production.rb
# runs during Rails.application.configure, and autoloading there raises. See
# config.autoload_lib's ignore list in config/application.rb.
module AppHost
  FALLBACK = "example.com".freeze

  PREVIEW_VAR = "PREVIEW_APP".freeze

  DEPLOYED_SOURCES = %w[APP_HOST RAILWAY_PUBLIC_DOMAIN].freeze
  PREVIEW_SOURCES  = DEPLOYED_SOURCES.reverse.freeze

  def self.resolve(env = ENV)
    sources_for(env).filter_map { |name| host_from(env[name]) }.first || FALLBACK
  end

  def self.sources_for(env)
    env[PREVIEW_VAR].to_s.strip.empty? ? DEPLOYED_SOURCES : PREVIEW_SOURCES
  end
  private_class_method :sources_for

  # Parsed with a scheme forced on, so a bare host and a full URL take the same
  # path instead of one of them returning nil.
  #
  # #presence, not just the nil check: URI.parse("https://") returns an empty
  # string rather than nil, so a value of "https://" would otherwise be treated
  # as a resolved host — skipping both the next source and FALLBACK, and
  # producing exactly the blank host this class exists to rule out.
  def self.host_from(value)
    text = value.to_s.strip
    return if text.empty?

    host = URI.parse(text.include?("//") ? text : "https://#{text}").host
    host.to_s.strip.empty? ? nil : host
  rescue URI::InvalidURIError
    nil
  end
  private_class_method :host_from
end
