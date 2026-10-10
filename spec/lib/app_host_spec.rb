require "rails_helper"
require Rails.root.join("lib/boot/app_host")

RSpec.describe AppHost do
  describe ".resolve" do
    it "prefers APP_HOST over the Railway-injected domain" do
      host = described_class.resolve(
        "APP_HOST" => "https://coding-gym.pro",
        "RAILWAY_PUBLIC_DOMAIN" => "web-production-246e40.up.railway.app"
      )

      expect(host).to eq("coding-gym.pro")
    end

    # Railway injects a bare host, and URI.parse(bare).host is nil.
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

  describe "on a preview deployment" do
    # A PR environment inherits production's APP_HOST, which would point the preview app at production's host.
    it "prefers the injected Railway domain over an inherited APP_HOST" do
      host = described_class.resolve(
        "PREVIEW_APP" => "1",
        "APP_HOST" => "https://coding-gym.pro",
        "RAILWAY_PUBLIC_DOMAIN" => "web-code-gym-rails-pr-118.up.railway.app"
      )

      expect(host).to eq("web-code-gym-rails-pr-118.up.railway.app")
    end

    it "still falls back to APP_HOST when no Railway domain is injected" do
      expect(described_class.resolve("PREVIEW_APP" => "1", "APP_HOST" => "https://coding-gym.pro"))
        .to eq("coding-gym.pro")
    end

    it "treats a blank preview flag as not-preview, so APP_HOST keeps precedence" do
      host = described_class.resolve(
        "PREVIEW_APP" => "   ",
        "APP_HOST" => "https://coding-gym.pro",
        "RAILWAY_PUBLIC_DOMAIN" => "pr.up.railway.app"
      )

      expect(host).to eq("coding-gym.pro")
    end

    # AppHost reads ENV directly only because it runs before autoloading is available.
    it "reads the same variable PreviewEnvironment gates on" do
      expect(described_class::PREVIEW_VAR).to eq(PreviewEnvironment::VAR)
    end
  end

  describe "a value that parses to an empty host" do
    # URI.parse("https://").host is "", so without a blank check this would resolve to a blank host.
    it "falls through to the next source rather than resolving blank" do
      expect(described_class.resolve("APP_HOST" => "https://", "RAILWAY_PUBLIC_DOMAIN" => "pr.up.railway.app"))
        .to eq("pr.up.railway.app")
    end

    it "falls through to FALLBACK when it is the only source" do
      expect(described_class.resolve("APP_HOST" => "https://")).to eq(described_class::FALLBACK)
      expect(described_class.resolve("APP_HOST" => "https:///")).to eq(described_class::FALLBACK)
    end
  end
end
