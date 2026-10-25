require "rails_helper"

RSpec.describe "desktop stylesheet" do
  let(:path) { Rails.root.join("app/assets/stylesheets/desktop.css") }
  let(:rules) { ViewStyles.stylesheet_rules(path) }

  it "holds only rules that apply at 900px and wider, so no phone width ever reads it" do
    expect(rules).not_to be_empty
    rules.each do |rule|
      expect(rule.media).to eq([ "@media (min-width: 900px)" ]), "#{rule.selectors.join(', ')} sits under #{rule.media.inspect}"
    end
  end

  it "loads after the phone card styles, so a desktop rule wins a tie with the phone rule it replaces" do
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    phone = layout.index('stylesheet_link_tag "phone_cards"')
    desktop = layout.index('stylesheet_link_tag "desktop"')

    expect(phone).to be_present
    expect(desktop).to be_present
    expect(desktop).to be > phone
  end
end
