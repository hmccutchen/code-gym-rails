require "rails_helper"

RSpec.describe "Settings partials' styles", type: :system do
  def styles(selector, *properties)
    page.evaluate_script(<<~JS)
      (() => {
        const style = getComputedStyle(document.querySelector(#{selector.to_json}));
        return #{properties.to_json}.map(property => style[property]);
      })()
    JS
  end

  def rem(value)
    "#{(value * page.evaluate_script('parseFloat(getComputedStyle(document.documentElement).fontSize)')).round(1).to_s.delete_suffix('.0')}px"
  end

  def open_disclosures
    page.execute_script("document.querySelectorAll('details.card').forEach(details => details.open = true)")
  end

  [ 390, 1024 ].each do |width|
    context "at #{width}px" do
      before { resize(width) }

      it "lays out the difficulty controls, the suggestion outline and the kind guide in a mix row" do
        visit_as(create_fake_provider_user)
        visit setup_path(suggested_level: "mid_level", suggested: [ "code_review" ])
        open_disclosures
        box = '.mix-difficulty[data-kind="code_review"]'

        expect(styles(box, "display", "fontSize", "paddingTop", "borderTopWidth", "gridColumnStart", "gridColumnEnd"))
          .to eq([ "block", "16px", "0px", "0px", "1", "-1" ])
        expect(styles("#{box} legend", "paddingLeft", "fontSize")).to eq([ "0px", rem(0.85) ])
        expect(styles("#{box} .mix-level", "display", "minHeight", "borderTopLeftRadius")).to eq([ "flex", "48px", "8px" ])
        expect(styles("#{box} .switch-row", "minHeight", "marginTop")).to eq([ "48px", rem(0.5) ])
        expect(styles("#{box}.mix-suggested", "outlineStyle", "outlineWidth", "outlineOffset")).to eq([ "solid", "2px", "4px" ])
        expect(styles(".mix-row .kind-about", "gridColumnStart", "gridColumnEnd", "marginBottom")).to eq([ "1", "-1", "0px" ])
        widths = page.evaluate_script("(f => [f.querySelector('.mix-level'), f].map(el => el.getBoundingClientRect().width))(document.querySelector(#{box.to_json}))")
        expect(widths.first).to be_within(0.5).of(widths.last)
      end

      it "spaces the display groups and their hints" do
        visit_as(create_fake_provider_user)
        visit setup_path
        open_disclosures

        expect(styles(".display-group", "display", "rowGap", "columnGap", "fontSize", "paddingTop", "borderTopWidth"))
          .to eq([ "flex", rem(0.5), rem(0.9), rem(0.85), rem(0.6), "0px" ])
        expect(styles(".display-group legend", "paddingLeft", "marginBottom")).to eq([ "0px", rem(0.35) ])
        expect(styles(".display-group label", "marginBottom", "color")).to eq([ "0px", computed_color("--text") ])
        expect(styles(".display-hint", "flexBasis", "marginTop")).to eq([ "100%", "0px" ])
      end

      it "spaces the key guide's blocks and indents its lists" do
        visit_as(User.create!(email: "keyless-#{SecureRandom.hex(3)}@example.com", name: "Keyless", **chosen_track(true)))
        visit setup_path

        expect(styles(".key-guide > .hint + .hint", "marginTop")).to eq([ rem(0.5) ])
        expect(styles(".key-guide ol", "paddingLeft")).to eq([ rem(1.25) ])
        expect(styles(".key-guide ul", "paddingLeft")).to eq([ rem(1.25) ])
      end
    end
  end
end
