require "rails_helper"

RSpec.describe "Content security policy", type: :request do
  let(:user) { create_fake_provider_user }

  def policy
    login_as(user)
    get setup_path
    response.headers["Content-Security-Policy"]
  end

  it "allows a script only from this origin, the two CDN packages, or a nonce it issued" do
    directive = policy[/script-src [^;]+/]

    expect(directive).to include("'self'")
    expect(directive.split).not_to include("https://cdn.jsdelivr.net", "https://cdn.jsdelivr.net/")
    expect(directive).to match(/'nonce-[^']+'/)
    expect(directive).not_to include("'unsafe-inline'")
    expect(directive).not_to include("'unsafe-eval'")
  end

  it "issues a fresh nonce per request, so one page's nonce cannot authorize another's script" do
    expect(policy[/'nonce-([^']+)'/, 1]).not_to eq(policy[/'nonce-([^']+)'/, 1])
  end

  it "carries that nonce on every script tag the importmap renders" do
    login_as(user)
    get setup_path
    nonce = response.headers["Content-Security-Policy"][/'nonce-([^']+)'/, 1]

    tags = Nokogiri::HTML(response.body).css("script")
    expect(tags.map { |tag| tag["type"] }).to include("importmap", "module")
    tags.each do |tag|
      expect(tag["nonce"]).to eq(nonce) if tag["src"].blank?
    end
  end

  it "covers every remote module a script names with a package directory, never a whole host" do
    sources = policy[/script-src [^;]+/].split.select { |source| source.start_with?("https://") }
    remote_urls = Dir[Rails.root.join("app/{javascript,assets/javascripts}/**/*.js")].flat_map do |path|
      File.read(path).scan(%r{https://[^"'`\s]+})
    end

    expect(remote_urls).not_to be_empty
    expect(sources).to all(match(%r{\Ahttps://[^/]+/.+/\z}))
    remote_urls.each do |url|
      expect(sources.any? { |source| url.start_with?(source) }).to be(true), "#{url} is outside every script-src source"
    end
  end
end
