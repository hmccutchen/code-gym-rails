require "rails_helper"

RSpec.describe "Content security policy", type: :request do
  let(:user) { create_fake_provider_user }

  def policy
    login_as(user)
    get setup_path
    response.headers["Content-Security-Policy"]
  end

  it "allows a script only from this origin, the module CDN, or a nonce it issued" do
    directive = policy[/script-src [^;]+/]

    expect(directive).to include("'self'")
    expect(directive).to include("https://cdn.jsdelivr.net")
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

  it "names the CDN the two dynamic imports actually reach for" do
    sources = %w[parsons_controller mermaid_controller].map do |name|
      Rails.root.join("app/javascript/controllers/#{name}.js").read
    end

    expect(sources).to all(include("https://cdn.jsdelivr.net/"))
  end
end
