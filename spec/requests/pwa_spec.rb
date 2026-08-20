require "rails_helper"

RSpec.describe "PWA", type: :request do
  # The palette the layout renders with. The manifest has to restate these
  # values as literals — a JSON file cannot read a CSS custom property — so the
  # assertions below read them back out of the layout, and drift in either
  # place fails here rather than shipping a home-screen app whose launch screen
  # doesn't match the app it launches.
  def layout_color(token)
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    layout[/--#{token}:\s*(#[0-9a-f]{3,8})/i, 1]
  end

  describe "GET /manifest.json" do
    subject(:manifest) { JSON.parse(response.body) }

    before { get "/manifest.json" }

    # Served by Rails' own PwaController, which does not inherit
    # ApplicationController. The manifest is fetched before any session exists,
    # so a login redirect here would leave the app uninstallable.
    it "is reachable without a session" do
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
    end

    it "declares a standalone app rooted at the dashboard" do
      expect(manifest).to include(
        "name" => "Code Gym",
        "short_name" => "Code Gym",
        "display" => "standalone",
        "start_url" => "/",
        "scope" => "/"
      )
    end

    it "colors the launch screen and status bar from the layout's palette" do
      expect(manifest["background_color"]).to eq(layout_color("bg"))
      expect(manifest["theme_color"]).to eq(layout_color("surface"))
    end

    # The route pins format: false. Without it the pattern carries an optional
    # (.:format) that a request can override, and the JSON template is then
    # asked for as HTML — MissingTemplate, i.e. a 500 on a path that needs no
    # session and that any crawler appending an extension will find.
    it "serves no format but JSON" do
      get "/manifest.json.html"

      expect(response).to have_http_status(:not_found)
    end

    it "points every icon at artwork that exists" do
      sources = manifest["icons"].map { |icon| icon["src"] }

      expect(sources).to include("/icon.svg", "/icon-192.png", "/icon.png")
      sources.each do |src|
        expect(Rails.public_path.join(src.delete_prefix("/"))).to exist
      end
    end

    it "offers a maskable icon" do
      expect(manifest["icons"].map { |icon| icon["purpose"] }).to include("maskable")
    end
  end

  describe "the layout's install tags" do
    before { get login_path }

    # apple-mobile-web-app-capable, not the manifest, is what drops Safari's
    # address bar, reload and text-size buttons on iOS before 17.4.
    it "declares the app installable and standalone-capable" do
      expect(response.body).to include(%(<link rel="manifest" href="/manifest.json">))
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-capable" content="yes">))
      expect(response.body).to include(%(<meta name="mobile-web-app-capable" content="yes">))
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-status-bar-style" content="black">))
    end

    # The third copy of --surface, after the custom property and the manifest.
    # Without this the manifest assertion above can be brought back into line
    # on its own and leave the browser-chrome tint on the old value.
    it "tints the browser chrome from the same palette as the manifest" do
      expect(response.body).to include(%(<meta name="theme-color" content="#{layout_color("surface")}">))
    end

    it "names and illustrates the home screen entry" do
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-title" content="Code Gym">))
      expect(response.body).to include(%(<link rel="apple-touch-icon" href="/apple-touch-icon.png">))
      expect(Rails.public_path.join("apple-touch-icon.png")).to exist
    end

    # The nav row is tight enough on a phone that the bolt has to go, and the
    # stylesheet can only hide it while it is an element of its own. Inline it
    # back into the brand text and the wordmark starts wrapping again with
    # nothing failing to say so. This is the logged-out brand; dashboard_spec's
    # "brand title link" covers the linked one.
    it "keeps the brand's bolt separately addressable from the wordmark" do
      expect(response.body).to include(%(<span class="brand"><span class="brand-mark">⚡</span> Code Gym</span>))
    end
  end
end
