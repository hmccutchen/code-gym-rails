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

    it "points every icon at artwork that exists, versioned by its bytes" do
      sources = manifest["icons"].map { |icon| icon["src"] }
      helper = Object.new.extend(PublicFileHelper)

      expect(sources).to eq(%w[icon-192.png icon-512.png icon-maskable-512.png].map { |name| helper.versioned_public_path(name) })
      sources.each do |src|
        expect(Rails.public_path.join(src.delete_prefix("/").split("?").first)).to exist
      end
    end

    it "offers a maskable icon" do
      expect(manifest["icons"].map { |icon| icon["purpose"] }).to include("maskable")
    end
  end

  describe "the layout's install tags" do
    before { get login_path }

    it "declares the app installable and standalone-capable, including on iOS before 17.4" do
      expect(response.body).to include(%(<link rel="manifest" href="/manifest.json">))
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-capable" content="yes">))
      expect(response.body).to include(%(<meta name="mobile-web-app-capable" content="yes">))
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-status-bar-style" content="black">))
    end

    # The third copy of --surface; without this the manifest can be fixed alone and leave the tint stale.
    it "tints the browser chrome from the same palette as the manifest" do
      expect(response.body).to include(%(<meta name="theme-color" content="#{layout_color("surface")}">))
    end

    it "versions the favicon by its bytes, since production caches public files for a year" do
      expect(response.body).to include(%(<link rel="icon" href="#{Object.new.extend(PublicFileHelper).versioned_public_path("favicon.ico")}" sizes="16x16 32x32 48x48">))
    end

    it "offers a larger favicon, so a high-density screen never enlarges a small one" do
      expect(response.body).to include(%(<link rel="icon" type="image/png" href="#{Object.new.extend(PublicFileHelper).versioned_public_path("favicon-96.png")}" sizes="96x96">))
      expect(Rails.public_path.join("favicon-96.png")).to exist
    end

    it "names and illustrates the home screen entry" do
      expect(response.body).to include(%(<meta name="apple-mobile-web-app-title" content="Code Gym">))
      expect(response.body).to include(%(<link rel="apple-touch-icon" href="#{Object.new.extend(PublicFileHelper).versioned_public_path("apple-touch-icon.png")}">))
      expect(Rails.public_path.join("apple-touch-icon.png")).to exist
    end

    it "keeps the brand link free of the hover underline, which a tap would leave stuck on a touch screen" do
      expect(response.body).to include("nav .brand:hover { text-decoration: none; }")
    end
  end

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

  describe "the bottom tab bar" do
    let(:layout) { Rails.root.join("app/views/layouts/application.html.erb").read }
    let(:standalone_block) { layout[/@media \(display-mode: standalone\) \{(.*?)\n    \}/m, 1] }

    it "is shown only from inside the app's one standalone-mode media query" do
      expect(standalone_block).to include("body .tab-bar { display: flex; }")
      expect(layout.scan(/^\s*[^{}\n]*\.tab-bar \{[^}]*display: (\w+)/).flatten).to eq(%w[flex none])
    end

    it "replaces the collapsed menu while it shows" do
      expect(standalone_block).to include("body nav .nav-toggle, body nav .nav-links, body nav .nav-links[data-open] { display: none; }")
    end

    it "lets the page reach under the home indicator, so the bar can pad itself clear of it" do
      get login_path

      expect(response.body).to include("viewport-fit=cover")
      expect(layout).to include("env(safe-area-inset-bottom)")
    end

    it "keeps the page column clear of a landscape notch, which viewport-fit=cover lets content reach" do
      ViewStyles.rules(layout).select { |rule| rule.selectors == [ ".container" ] }.each do |rule|
        padding = [ rule.declaration("padding"), rule.declaration("padding-inline") ].compact.join(" ")
        expect(padding).to include("env(safe-area-inset-left)").and include("env(safe-area-inset-right)")
      end
    end
  end

  describe "the swap sheet's scrim" do
    it "falls back to a literal --bg where ::backdrop doesn't see custom properties, with or without color-mix()" do
      layout = Rails.root.join("app/views/layouts/application.html.erb").read
      rule = layout[/^\s*\.daily-kind-sheet::backdrop \{([^}]*)\}/, 1]
      bg = layout_color("bg")
      red, green, blue = bg.delete("#").scan(/../).map(&:hex)

      expect(rule.scan(/background:\s*([^;]+);/).flatten).to eq(
        [ "rgba(#{red}, #{green}, #{blue}, .7)", "color-mix(in srgb, var(--bg, #{bg}) 70%, transparent)" ]
      )
    end
  end

  describe "section slot accents" do
    let(:rules) { ViewStyles.rules(Rails.root.join("app/views/layouts/application.html.erb").read) }

    it "colors only the exercise sections, never the dashboard panels and admin cards that share .section" do
      plain = rules.select { |rule| rule.selectors.include?(".section") }

      expect(plain.map(&:declarations).join).not_to include("slot-accent")
      expect(rules.find { |rule| rule.selectors == [ "[data-slot]" ] }.declaration("--slot-accent")).to eq("var(--slot-1)")
      expect(rules.find { |rule| rule.selectors == [ ".section[data-slot]" ] }.declaration("box-shadow")).to include("var(--slot-accent)")
    end
  end

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
      rules = layout.lines.grep(/overscroll-behavior/)
      list_rules = rules.grep(/\.daily-kind-list \{/)
      expect(list_rules.size).to eq(1)
      expect(list_rules.first).to include("overscroll-behavior: contain;")
      expect(rules.grep_v(/\.daily-kind-list \{/).size).to eq(1)
    end

    it "is rendered on every page, signed in or not" do
      get login_path

      expect(response.body).to include('id="pull-refresh"')
    end
  end
end
