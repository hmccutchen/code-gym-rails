require "uri"

# APP_HOST wins, except on a PR app, which inherits production's APP_HOST, so RAILWAY_PUBLIC_DOMAIN wins there.
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

  # #presence because URI.parse("https://").host is empty, which would otherwise pass as a resolved host.
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
