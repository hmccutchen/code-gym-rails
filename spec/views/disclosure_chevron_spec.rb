require "rails_helper"

RSpec.describe "disclosure chevrons" do
  let(:layout) { Rails.root.join("app/views/layouts/application.html.erb").read }

  it "draws every page's disclosure toggle with the layout's one chevron, never a text arrow" do
    Rails.root.glob("app/views/**/*.erb").each do |view|
      expect(view.read).not_to match(/content:\s*"[▶▼]/), "#{view.relative_path_from(Rails.root)} still draws a text arrow"
    end

    chevron = ViewStyles.rules(layout).find { |rule| rule.selectors.include?("details.section > summary::before") }
    expect(chevron.selectors).to include("details.review summary::before", "details.answers summary::before",
                                         "details.progress-group summary::before", ".learn-recognition summary::before",
                                         "details.card > summary::before")
  end

  it "draws a collapsible card's chevron in place of the browser's marker, turning it when the card opens" do
    closed = ViewStyles.rules(layout).find { |rule| rule.selectors.include?("details.section:not([open]) > summary::before") }
    card = ViewStyles.stylesheet_rules(Rails.root.join("app/assets/stylesheets/phone_cards.css"))
                     .find { |rule| rule.selectors == [ "details.card > summary" ] }

    expect(closed.selectors).to include("details.card:not([open]) > summary::before")
    expect(card.declaration("display")).to eq("flex")
    expect(card.declaration("list-style")).to eq("none")
  end
end
