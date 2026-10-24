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

  it "offsets .phone-page by .container's gutter properties instead of a copy of their values" do
    margins = phone_cards.select { |rule| rule.selectors.include?(".phone-page") }.filter_map { |rule| rule.declaration("margin-left") }

    expect(margins).to eq([ "calc(max(16px, env(safe-area-inset-left)) - var(--container-pad-left))" ])
    expect(File.read(Rails.root.join("app/assets/stylesheets/phone_cards.css"))).not_to include("1.5rem")
  end
end
