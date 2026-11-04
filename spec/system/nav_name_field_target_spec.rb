require "rails_helper"

RSpec.describe "Nav name field target", type: :system do
  def field_height = page.evaluate_script("document.querySelector('nav .name-editor-input').getBoundingClientRect().height")

  def sign_in_at(text_size)
    user = create_fake_provider_user
    user.update!(display_preferences: { "text_size" => text_size })
    visit_as(user)
    visit learn_path
  end

  [ "100", "140" ].each do |text_size|
    [ 768, 1024, 1280 ].each do |width|
      it "makes the name field at least 44px tall at #{width}px and #{text_size}% text, in the row or the open menu" do
        resize(width, height: 800)
        sign_in_at(text_size)
        find("#nav-toggle").click if page.has_css?("#nav-toggle", visible: :visible, wait: 0)

        expect(page).to have_css("nav .name-editor-input", visible: :visible)
        expect(field_height).to be >= 44
      end
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
