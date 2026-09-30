require "rails_helper"

# DisplayPreferences::OPTIONS is the one list of choices. Every choice other
# than a default has to do something in display.css, or picking it on Setup
# would save and render an attribute that changes nothing on the page.
RSpec.describe "display stylesheet" do
  let(:css) { Rails.root.join("app/assets/stylesheets/display.css").read }

  %w[text_size line_spacing font].each do |setting|
    it "styles every #{setting.humanize(capitalize: false)} choice but the default" do
      DisplayPreferences::OPTIONS.fetch(setting).drop(1).each do |value|
        expect(css).to include(%(html[data-#{setting.dasherize}="#{value}"])), "no rule for #{setting}=#{value}"
      end
    end
  end

  it "ships the font file behind every @font-face" do
    css.scan(/url\("([^"]+)"\)/).flatten.each do |file|
      expect(Rails.root.join("app/assets/fonts", file)).to exist
    end
  end
end
