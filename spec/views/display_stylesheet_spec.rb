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

  it "ships OpenDyslexic exactly as its author releases it, since only an unmodified copy may keep the name" do
    {
      "opendyslexic-regular.woff2" => "5a7c8f7e613bfdb8d3dd3df6151635dc454b8a58293402a78acda493c7bf383d",
      "opendyslexic-bold.woff2" => "078d02b066bb2d495dc3bcecb90734360415292bdfef60a3d68012e81311b50d",
      "opendyslexic-LICENSE.txt" => "caafcccfb70fc72458fcbda812ec8f0a06cb300cbabb87eabbb30b946124394b"
    }.each do |file, digest|
      expect(Digest::SHA256.file(Rails.root.join("app/assets/fonts", file)).hexdigest).to eq(digest), "#{file} differs from the release"
    end
  end

  it "names the same prose elements in every reading rule, so spacing, font and wrapping never part ways" do
    lists = css.scan(/html\[data-[^\]]+\] :is\(([^)]+)\)/m).flatten.map { |list| list.split(",").map(&:strip) }

    expect(lists.size).to be >= 4
    expect(lists.uniq.size).to eq(1)
  end

  it "keeps inline code unbroken under OpenDyslexic only outside the elements that break words for every font" do
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    excluded = css[/code:not\(:is\(([^)]+)\) code\)/, 1].split(",").map(&:strip) - %w[pre]

    excluded.each do |selector|
      expect(layout).to match(/^\s*#{Regexp.escape(selector)} \{[^}]*overflow-wrap: anywhere/), "#{selector} no longer breaks words for every font"
    end
  end

  it "ships the font file behind every @font-face" do
    css.scan(/url\("([^"]+)"\)/).flatten.each do |file|
      expect(Rails.root.join("app/assets/fonts", file)).to exist
    end
  end
end
