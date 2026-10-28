require "rails_helper"

RSpec.describe "Nav in a notched landscape phone", type: :system do
  let(:user) { create_fake_provider_user }

  def visit_learn_with_notch(width:, height:, inset:)
    resize(width, height: height)
    set_safe_area(left: inset, right: inset)
    visit_as(user)
    visit learn_path
  end

  it "lines the brand and the last link up with the page content on a Pro Max in landscape" do
    visit_learn_with_notch(width: 932, height: 430, inset: 59)

    content = container_content
    expect(rect("nav .brand")["left"]).to be_within(0.5).of(content["left"])
    expect(rects("nav .nav-links a").last["right"]).to be_within(0.5).of(content["right"])
    expect(content["left"]).to be_within(0.5).of(59)
  end

  it "puts the brand and the last link one notch from the edge at 844px" do
    visit_learn_with_notch(width: 844, height: 390, inset: 44)

    expect(edges("nav .brand").sole.first).to be_within(0.5).of(44)
    expect(client_width - rects("nav .nav-links a").last["right"]).to be_within(0.5).of(44)
    expect(sideways_overflow).to eq(0)
  end

  [ "100", "140" ].each do |text_size|
    it "fits every link in the row just above the width where it collapses, with a 59px notch at #{text_size}% text" do
      user.update!(display_preferences: { "text_size" => text_size })
      visit_learn_with_notch(width: 1400, height: 430, inset: 59)

      resize(narrowest_uncollapsed_nav_width(height: 430), height: 430)

      expect(page).to have_link("Settings", visible: :visible)
      expect(edges("nav .brand").sole.first).to be_within(0.5).of(59)
      overflow = page.evaluate_script(<<~JS)
        [document.querySelector("nav .inner"), document.documentElement].map(el => el.scrollWidth - el.clientWidth)
      JS
      expect(overflow).to eq([ 0, 0 ])
    end
  end
end
