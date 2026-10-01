require "rails_helper"

# What the layout renders from a user's display preferences. A user who has
# chosen nothing keeps the existing display defaults: no attribute on <html>,
# no display stylesheet, the dark status bar and the outlined logo.
RSpec.describe "Display preferences in the layout", type: :request do
  let(:user) { create_user_with_key }

  it "renders the decorative pattern outside the moving content by default, including when signed out" do
    [ login_path, history_path ].each do |path|
      login_as(user) if path == history_path
      get path
      document = Nokogiri::HTML5(response.body)
      expect(document.css("body > #background-pattern[aria-hidden='true']").size).to eq(1)
      expect(document.css("[data-pull-content] #background-pattern")).to be_empty
      expect(response.body).to match(%r{url\(["']?/assets/gym-pattern-tile-dark-[a-f0-9]+\.png})
    end
  end

  it "accepts off through the profile boundary and omits the layer even on Setup" do
    login_as(user)
    patch profile_path, params: { user: { display_preferences: { background_pattern: "off" } } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.display_preferences).to eq("background_pattern" => "off")
    [ history_path, setup_path ].each do |path|
      get path
      expect(Nokogiri::HTML5(response.body).css("#background-pattern")).to be_empty
    end

    patch profile_path, params: { user: { display_preferences: { background_pattern: "on" } } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.display_preferences).to eq({})
  end

  def html_tag
    response.body[/<html[^>]*>/]
  end

  def theme_colors
    Nokogiri::HTML5(response.body).css('meta[name="theme-color"]').map { |meta| [ meta["content"], meta["media"] ] }
  end

  def display_links
    Nokogiri::HTML5(response.body).css('link[rel="stylesheet"]').select { |link| link["href"].include?("display") }
  end

  context "for a user who has chosen nothing" do
    before do
      login_as(user)
      get history_path
    end

    it "renders no new attribute, stylesheet or logo markup" do
      expect(html_tag).to eq('<html lang="en">')
      expect(display_links).to be_empty
      expect(response.body).not_to include("<picture>")
      expect(response.body).to include('<meta name="apple-mobile-web-app-status-bar-style" content="black">')
      expect(theme_colors).to eq([ [ "#1a1a2e", nil ] ])
    end
  end

  context "for a user with stored preferences" do
    before do
      user.update!(display_preferences: { "theme" => "light", "text_size" => "140", "font" => "atkinson" })
      login_as(user)
      get history_path
    end

    it "renders each choice on <html> for the first paint" do
      expect(html_tag).to eq('<html lang="en" data-theme="light" data-text-size="140" data-font="atkinson">')
    end

    it "links the display stylesheet and applies the light palette everywhere" do
      expect(display_links.map { |link| [ link["href"][/display(_light)?/], link["media"] ] })
        .to contain_exactly([ "display", nil ], [ "display_light", "all" ])
    end

    it "shows the plain logo and asks iOS for the white status bar" do
      source = Nokogiri::HTML5(response.body).at_css("nav picture source")
      expect(source["srcset"]).to include("logo")
      expect(source["srcset"]).not_to include("outlined")
      expect(source["media"]).to eq("all")
      expect(response.body).to include('<meta name="apple-mobile-web-app-status-bar-style" content="default">')
      expect(theme_colors).to eq([ [ "#ffffff", "all" ], [ "#1a1a2e", nil ] ])
    end
  end

  it "applies the light palette only when the device asks, for Match my device" do
    user.update!(display_preferences: { "theme" => "device" })
    login_as(user)
    get history_path

    light = display_links.find { |link| link["href"].include?("display_light") }
    expect(light["media"]).to eq("(prefers-color-scheme: light)")
    expect(theme_colors).to eq([ [ "#ffffff", "(prefers-color-scheme: light)" ], [ "#1a1a2e", nil ] ])
    expect(response.body).to include('<meta name="apple-mobile-web-app-status-bar-style" content="black">')
  end

  it "follows the device on a signed-out page" do
    get login_path

    expect(html_tag).to eq('<html lang="en" data-theme="device">')
    expect(display_links.map { |link| link["media"] }).to include("(prefers-color-scheme: light)")
    expect(theme_colors.first).to eq([ "#ffffff", "(prefers-color-scheme: light)" ])
  end

  it "links the stylesheets on Setup with the light palette off, so a choice there applies at once" do
    login_as(user)
    get setup_path

    expect(html_tag).to eq('<html lang="en">')
    expect(display_links.map { |link| link["media"] }).to contain_exactly(nil, "not all")
    expect(response.body).to include('id="display-preferences"')
  end
end
