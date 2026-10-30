require "rails_helper"

RSpec.describe "container gutter" do
  let(:layout) { ViewStyles.rules(Rails.root.join("app/views/layouts/application.html.erb").read) }
  let(:phone_cards) { ViewStyles.stylesheet_rules(Rails.root.join("app/assets/stylesheets/phone_cards.css")) }

  def container_rules
    layout.select { |rule| rule.selectors.include?(".container") }
  end

  it "builds .container's side padding from its gutter properties at every width" do
    expect(container_rules.size).to eq(2)
    container_rules.each do |rule|
      expect(rule.declaration("--container-pad-left")).to match(/\Amax\(.+env\(safe-area-inset-left\)\)\z/)
      expect(rule.declaration("--container-pad-right")).to match(/\Amax\(.+env\(safe-area-inset-right\)\)\z/)
    end
    expect(container_rules.first.declaration("padding")).to eq("0 var(--container-pad-right) 0 var(--container-pad-left)")
  end

  it "caps the nav row at the plain column's cap less both side insets, and measures the collapse inside it" do
    expect(container_rules.map { |rule| rule.declaration("--container-max") }).to eq(%w[800px 920px])
    expect(container_rules.first.declaration("max-width")).to eq("var(--container-max)")

    inner = layout.find { |rule| rule.selectors == [ "nav .inner" ] && rule.media.empty? }
    expect(inner.declaration("max-width")).to eq("calc(var(--container-max) - env(safe-area-inset-left) - env(safe-area-inset-right))")
    expect(inner.declaration("container-type")).to eq("inline-size")
  end

  it "offsets .phone-page by .container's gutter properties instead of a copy of their values" do
    margins = phone_cards.select { |rule| rule.selectors.include?(".phone-page") }.filter_map { |rule| rule.declaration("margin-left") }

    expect(margins).to eq([ "calc(var(--page-gutter-left) - var(--container-pad-left))" ])
    expect(File.read(Rails.root.join("app/assets/stylesheets/phone_cards.css"))).not_to include("1.5rem")
  end

  it "insets a full-width card page and Today by the same one formula as .phone-page" do
    margin_rules = phone_cards.select { |rule| rule.declaration("margin-left") }

    expect(margin_rules.size).to eq(1)
    expect(margin_rules.first.selectors).to contain_exactly(".phone-page", ".card-page", ".today-page")
    expect(margin_rules.first.media).to eq([ "@media (max-width: 599.98px)" ])
  end

  it "runs a phone page's outermost cards to the safe area by cancelling the page gutter" do
    bleed = phone_cards.select { |rule| rule.declaration("margin-inline") && rule.media == [ "@media (max-width: 599.98px)" ] }

    expect(bleed.size).to eq(1)
    expect(bleed.first.declaration("margin-inline")).to eq(
      "calc(env(safe-area-inset-left) - var(--page-gutter-left)) calc(env(safe-area-inset-right) - var(--page-gutter-right))"
    )
    expect(bleed.first.declaration("border-inline")).to eq("0")
  end

  it "widens a wide page and the nav to 1040px of content in one rule, built from the gutter properties" do
    desktop = ViewStyles.stylesheet_rules(Rails.root.join("app/assets/stylesheets/desktop.css"))
    wide = desktop.select { |rule| rule.selectors.include?(".container.container-wide") }

    expect(wide.size).to eq(1)
    expect(wide.first.selectors).to contain_exactly(".container.container-wide", "nav .inner")
    expect(wide.first.declaration("max-width")).to eq("calc(1040px + var(--container-pad-left) + var(--container-pad-right))")
  end
end
