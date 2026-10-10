require "rails_helper"

RSpec.describe "PWA", type: :request do
  # The manifest restates the layout's palette as literals, so read them from the layout to catch drift.
  def layout_color(token)
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    layout[/--#{token}:\s*(#[0-9a-f]{3,8})/i, 1]
  end

  describe "GET /manifest.json" do
    subject(:manifest) { JSON.parse(response.body) }

    before { get "/manifest.json" }

    # The manifest is fetched before any session exists, so a login redirect would make the app uninstallable.
    it "is reachable without a session" do
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
    end

    it "declares a standalone app rooted at the dashboard" do
      expect(manifest).to include(
        "name" => "Code Gym",
        "short_name" => "Code Gym",
        "description" => "Daily personalized coding exercises.",
        "display" => "standalone",
        "start_url" => "/",
        "scope" => "/"
      )
    end

    it "colors the launch screen and status bar from the layout's palette" do
      expect(manifest["background_color"]).to eq(layout_color("bg"))
      expect(manifest["theme_color"]).to eq(layout_color("surface"))
    end

    # Without format: false, a request for .html asks for a missing template and gets a 500.
    it "serves no format but JSON" do
      get "/manifest.json.html"

      expect(response).to have_http_status(:not_found)
    end

    it "points every icon at artwork that exists" do
      sources = manifest["icons"].map { |icon| icon["src"] }

      expect(sources).to include("/icon-192.png", "/icon-512.png", "/icon-maskable-512.png")
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

    # apple-mobile-web-app-capable, not the manifest, makes iOS before 17.4 launch standalone.
    it "declares the app installable and standalone-capable" do
      expect(response.body).to include(%(<link rel="manifest" href="/manifest.json">))
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-capable" content="yes">))
      expect(response.body).to include(%(<meta name="mobile-web-app-capable" content="yes">))
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-status-bar-style" content="black">))
    end

    # The third copy of --surface; without this the manifest can be fixed alone and leave the tint stale.
    it "tints the browser chrome from the same palette as the manifest" do
      expect(response.body).to include(%(<meta name="theme-color" content="#{layout_color("surface")}">))
    end

    it "names and illustrates the home screen entry" do
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-title" content="Code Gym">))
      expect(response.body).to include(%(<link rel="apple-touch-icon" href="/apple-touch-icon.png">))
      expect(Rails.public_path.join("apple-touch-icon.png")).to exist
    end

    # A tap leaves a touch screen in :hover, so the global underline would stick on the logo.
    it "keeps the brand link free of the hover underline" do
      expect(response.body).to include("nav .brand:hover { text-decoration: none; }")
    end
  end

  # Asserted against the stylesheet because Playwright cannot emulate display-mode.
  describe "the name editor in standalone mode" do
    let(:standalone_block) do
      Rails.root.join("app/views/layouts/application.html.erb").read[
        /@media \(display-mode: standalone\) \{(.*?)\n    \}/m, 1
      ]
    end

    it "hides it from inside the app's one standalone-mode media query" do
      expect(standalone_block).to include("name-editor { display: none; }")
    end

    # A media query adds no specificity, so the hide needs two class selectors to beat the later base rule.
    it "outranks the base rule that comes after it" do
      expect(standalone_block).to include("nav .nav-links .name-editor")
    end
  end

  # Playwright cannot emulate display-mode, so assert the stylesheet; pull_to_refresh_spec covers the gesture.
  describe "the pull-to-refresh indicator" do
    let(:layout) { Rails.root.join("app/views/layouts/application.html.erb").read }
    let(:standalone_block) { layout[/@media \(display-mode: standalone\) \{(.*?)\n    \}/m, 1] }

    it "is shown only from inside the app's one standalone-mode media query" do
      expect(standalone_block).to include("body .pull-refresh { display: flex; }")
      expect(layout.scan(/^\s*[^{}\n]*\.pull-refresh \{[^}]*display: (\w+)/).flatten).to eq(%w[flex none])
    end

    it "outranks the hidden base rule that comes after it" do
      expect(layout.index("body .pull-refresh { display: flex; }")).to be < layout.index(".pull-refresh {\n      display: none;")
    end

    it "leaves the native bounce suppression scoped as it was" do
      expect(standalone_block).to include("html, body { overscroll-behavior-y: none; }")
      expect(layout.scan("overscroll-behavior").size).to eq(1)
    end

    it "is rendered on every page, signed in or not" do
      get login_path

      expect(response.body).to include('id="pull-refresh"')
    end
  end
end
