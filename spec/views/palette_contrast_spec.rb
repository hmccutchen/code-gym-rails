require "rails_helper"

# WCAG AA: 4.5:1 for text, 3:1 for focus and borders; light is display_light.css layered over the layout's :root.
RSpec.describe "palette contrast" do
  let(:layout) { Rails.root.join("app/views/layouts/application.html.erb").read }
  let(:rules) { ViewStyles.rules(layout) }
  let(:light_rules) { ViewStyles.stylesheet_rules(Rails.root.join("app/assets/stylesheets/display_light.css")) }

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

  def declared(rule_list, selector, property)
    rule_list.find { |rule| rule.selectors.include?(selector) }.declaration(property)
  end

  def background_of(selector)
    declared(rules, selector, "background")
  end

  def text_backgrounds(vars, code_background)
    review_block = over(background_of(".review-block"), vars["surface"])
    {
      "page" => vars["bg"],
      "surface" => vars["surface"],
      "code and fields" => code_background,
      "why-box" => over(background_of(".why-box"), vars["surface"]),
      "review block" => review_block,
      "rating pill on the surface" => over(background_of(".review-rating"), vars["surface"]),
      "rating pill in a review block" => over(background_of(".review-rating"), review_block)
    }
  end

  def ratios(color, backgrounds)
    backgrounds.transform_values { |background| contrast(color, background).round(2) }
  end

  shared_examples "an accessible palette" do
    it "keeps text and focus indicators legible over a fully opaque pattern pixel" do
      tint = rgb(vars.fetch("pattern-tint")).join(",")
      backdrop = over("rgba(#{tint},#{vars.fetch('pattern-opacity')})", vars["bg"])
      backgrounds = {
        "pattern" => backdrop,
        "notice over pattern" => over(background_of(".flash.notice"), backdrop),
        "alert over pattern" => over(background_of(".flash.alert"), backdrop)
      }
      %w[text accent-text muted green red yellow].each do |name|
        result = ratios(vars[name], backgrounds)
        expect(result.values).to all(be >= 4.5), "#{name}: #{result.inspect}"
      end
      expect(contrast(vars["focus-ring"], backdrop)).to be >= 3
    end

    %w[text accent-text muted].each do |name|
      it "keeps --#{name} at 4.5:1 or more on every background it sits on" do
        result = ratios(vars[name], text_backgrounds(vars, code_background))

        expect(result.values).to all(be >= 4.5), result.inspect
      end
    end

    it "keeps every highlighting color at 4.5:1 or more on code" do
      colors = rules.select { |rule| rule.selectors.any? { |selector| selector.start_with?("code.highlight") } }
        .filter_map { |rule| rule.declaration("color") }.uniq
        .to_h { |color| [ color, vars.fetch(color[/\Avar\(--([\w-]+)\)\z/, 1], color) ] }

      expect(colors.size).to be >= 6
      expect(colors.transform_values { |color| contrast(color, code_background).round(2) }.values).to all(be >= 4.5), colors.inspect
    end

    it "keeps white text at 4.5:1 or more on the button fill, at rest and on hover" do
      expect(contrast("#ffffff", vars["button-bg"])).to be >= 4.5
      expect(contrast("#ffffff", vars["button-bg-hover"])).to be >= 4.5
    end

    it "keeps the focus ring at 3:1 or more against the backgrounds around a field" do
      [ vars["bg"], vars["surface"], code_background ].each do |background|
        expect(contrast(vars["focus-ring"], background)).to be >= 3
      end
    end

    it "keeps --muted visibly dimmer than body text" do
      expect(contrast(vars["text"], vars["muted"])).to be >= 1.5
    end
  end

  context "dark, the default" do
    let(:vars) { ViewStyles.root_variables(layout) }
    let(:code_background) { vars["code-bg"] }

    it_behaves_like "an accessible palette"
  end

  context "light" do
    let(:vars) { ViewStyles.root_variables(layout).merge(ViewStyles.root_variables(light_rules)) }
    let(:code_background) { vars["code-bg"] }

    it_behaves_like "an accessible palette"

    it "keeps the status colors at 4.5:1 or more, including on their own tinted flash" do
      backgrounds = text_backgrounds(vars, code_background)
      %w[green red].each do |name|
        backgrounds["#{name} flash"] = over(declared(rules, ".flash.#{name == 'green' ? 'notice' : 'alert'}", "background"), vars["bg"])
      end

      %w[green red yellow].each do |name|
        result = ratios(vars[name], backgrounds)
        expect(result.values).to all(be >= 4.5), "#{name}: #{result.inspect}"
      end
    end

    it "keeps a field's border at 3:1 or more, since the border is what marks the field" do
      [ vars["bg"], vars["surface"], code_background ].each do |background|
        expect(contrast(vars["field-border"], background)).to be >= 3
      end
    end

    it "gives iOS and Android the light surface as the theme color" do
      expect(DisplayPreferences::LIGHT_THEME_COLOR).to eq(vars["surface"])
    end
  end
end
