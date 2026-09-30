require "rails_helper"

# The layout's shared colors against every background they sit on, read from
# the stylesheet itself so a palette edit is checked against the values that
# actually ship. WCAG AA: 4.5:1 for text, 3:1 for a focus indicator.
# docs/accessibility-audit-2026-09-29.md has the audit these pairs come from.
RSpec.describe "palette contrast" do
  let(:layout) { Rails.root.join("app/views/layouts/application.html.erb").read }
  let(:vars) { ViewStyles.root_variables(layout) }
  let(:rules) { ViewStyles.rules(layout) }

  def rgb(color)
    if (hex = color[/\A#(\h{3}|\h{6})\z/, 1])
      hex = hex.chars.map { |c| c * 2 }.join if hex.size == 3
      hex.scan(/../).map { |pair| pair.to_i(16) }
    else
      color[/rgba?\(([^)]+)\)/, 1].split(",").first(3).map(&:to_i)
    end
  end

  def alpha(color)
    color[/rgba\([^)]*,\s*([\d.]+)\)/, 1].to_f
  end

  def over(tint, base)
    rgb(tint).zip(rgb(base)).map { |top, bottom| (top * alpha(tint) + bottom * (1 - alpha(tint))).round }
      .then { |channels| format("#%02x%02x%02x", *channels) }
  end

  def luminance(color)
    rgb(color).map { |c| c / 255.0 }.map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
      .zip([ 0.2126, 0.7152, 0.0722 ]).sum { |c, weight| c * weight }
  end

  def contrast(a, b)
    lighter, darker = [ luminance(a), luminance(b) ].sort.reverse
    (lighter + 0.05) / (darker + 0.05)
  end

  def background_of(selector)
    rules.find { |rule| rule.selectors.include?(selector) }.declaration("background")
  end

  let(:text_backgrounds) do
    review_block = over(background_of(".review-block"), vars["surface"])
    {
      "page" => vars["bg"],
      "surface" => vars["surface"],
      "code and fields" => background_of("pre.snippet"),
      "why-box" => over(background_of(".why-box"), vars["surface"]),
      "review block" => review_block,
      "rating pill on the surface" => over(background_of(".review-rating"), vars["surface"]),
      "rating pill in a review block" => over(background_of(".review-rating"), review_block)
    }
  end

  %w[text accent-text muted].each do |name|
    it "keeps --#{name} at 4.5:1 or more on every background it sits on" do
      ratios = text_backgrounds.transform_values { |background| contrast(vars[name], background).round(2) }

      expect(ratios.values).to all(be >= 4.5), ratios.inspect
    end
  end

  it "keeps white text at 4.5:1 or more on the button fill, at rest and on hover" do
    expect(contrast("#ffffff", vars["button-bg"])).to be >= 4.5
    expect(contrast("#ffffff", vars["button-bg-hover"])).to be >= 4.5
  end

  it "keeps the focus ring at 3:1 or more against the backgrounds around a field" do
    [ vars["bg"], vars["surface"], background_of("pre.snippet") ].each do |background|
      expect(contrast(vars["focus-ring"], background)).to be >= 3
    end
  end

  it "keeps --muted visibly dimmer than body text" do
    expect(contrast(vars["text"], vars["muted"])).to be >= 1.5
  end
end
