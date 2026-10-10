require "rails_helper"

# Each non-default text size, line spacing and font must change something in display.css, or picking it would do nothing.
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
