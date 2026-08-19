require "rails_helper"
require Rails.root.join("lib/boot/app_host")

RSpec.describe AppHost do
  describe ".resolve" do
    # Production sets APP_HOST deliberately to its custom domain. An injected
    # value must never win over it.
    it "prefers APP_HOST over the Railway-injected domain" do
      host = described_class.resolve(
        "APP_HOST" => "https://coding-gym.pro",
        "RAILWAY_PUBLIC_DOMAIN" => "web-production-246e40.up.railway.app"
      )

      expect(host).to eq("coding-gym.pro")
    end

    # The bug this exists to fix: Railway injects a bare host, and
    # URI.parse("web-….up.railway.app").host is nil, which left every preview
    # app with default_url_options[:host] = nil and a broken magic link.
    it "resolves a bare host that carries no scheme" do
      expect(described_class.resolve("RAILWAY_PUBLIC_DOMAIN" => "web-code-gym-rails-pr-117.up.railway.app"))
        .to eq("web-code-gym-rails-pr-117.up.railway.app")
    end

    it "resolves a bare host in APP_HOST too" do
      expect(described_class.resolve("APP_HOST" => "coding-gym.pro")).to eq("coding-gym.pro")
    end

    it "falls back to the Railway domain when APP_HOST is absent or blank" do
      [ nil, "", "   " ].each do |absent|
        expect(described_class.resolve("APP_HOST" => absent, "RAILWAY_PUBLIC_DOMAIN" => "pr.up.railway.app"))
          .to eq("pr.up.railway.app"), "APP_HOST=#{absent.inspect} did not fall through"
      end
    end

    # A misconfigured deploy must still boot rather than raise at load.
    it "falls back to a placeholder when neither is set" do
      expect(described_class.resolve({})).to eq(AppHost::FALLBACK)
    end

    it "strips a port and a path if either is present" do
      expect(described_class.resolve("APP_HOST" => "https://coding-gym.pro:443/app")).to eq("coding-gym.pro")
    end
  end
end
