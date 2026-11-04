require "rails_helper"

RSpec.describe "Nav name field target", type: :system do
  def field_height = page.evaluate_script("document.querySelector('nav .name-editor-input').getBoundingClientRect().height")

  def field_in_row
    page.evaluate_script(<<~JS)
      (() => {
        const field = document.querySelector("nav .name-editor-input"), box = field.getBoundingClientRect();
        return { shown: getComputedStyle(field).display !== "none", width: box.width, right: box.right,
                 first_link_left: document.querySelector("nav .nav-links a").getBoundingClientRect().left,
                 rem: parseFloat(getComputedStyle(document.documentElement).fontSize) };
      })()
    JS
  end

  def sign_in_at(text_size)
    user = create_fake_provider_user
    user.update!(display_preferences: { "text_size" => text_size })
    visit_as(user)
    visit learn_path
  end

  [ [ "100", 1024 ], [ "100", 1280 ], [ "140", 1280 ], [ "140", 768 ] ].each do |text_size, width|
    it "makes the name field at least 44px tall at #{width}px and #{text_size}% text, in the row or the open menu" do
      resize(width, height: 800)
      sign_in_at(text_size)
      find("#nav-toggle").click if page.has_css?("#nav-toggle", visible: :visible, wait: 0)

      expect(page).to have_css("nav .name-editor-input", visible: :visible)
      expect(field_height).to be >= 44
    end
  end

  [ "100", "140" ].each do |text_size|
    it "hides the name field from the row rather than show it under 5rem or over a link, at #{text_size}% text" do
      sign_in_at(text_size)
      row_widths = (700..1300).step(10).select do |width|
        resize(width, height: 800)
        page.has_no_css?("#nav-toggle", visible: :visible, wait: 0)
      end

      fields = row_widths.map do |width|
        resize(width, height: 800)
        [ width, field_in_row ]
      end
      shown = fields.select { |_, field| field["shown"] }
      expect(shown.map(&:first)).to include(1280)
      shown.each do |width, field|
        expect(field["width"]).to be >= (5 * field["rem"]).floor, "#{width}px: #{field['width']}px wide"
        expect(field["right"]).to be <= field["first_link_left"], "#{width}px: the field reaches past the first link"
      end
      expect(shown.size).to be < row_widths.size
    end
  end

  it "makes the name field at least 44px tall in the open menu on a phone" do
    resize(390)
    sign_in_at("100")
    find("#nav-toggle").click

    expect(page).to have_css("nav .name-editor-input", visible: :visible)
    expect(field_height).to be >= 44
  end
end
