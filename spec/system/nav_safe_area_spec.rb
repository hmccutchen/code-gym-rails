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

  it "lines the brand and the last link up with the page column at 844px, one notch inside it" do
    visit_learn_with_notch(width: 844, height: 390, inset: 44)

    content = container_content
    expect(rect("nav .brand")["left"]).to be_within(0.5).of(content["left"])
    expect(rects("nav .nav-links a").last["right"]).to be_within(0.5).of(content["right"])
    expect(content["left"]).to be_within(0.5).of(22 + 44)
    expect(sideways_overflow).to eq(0)
  end

  [ "100", "140" ].each do |text_size|
    it "fits every link in the row just above the width where it collapses, with a 59px notch at #{text_size}% text" do
      user.update!(display_preferences: { "text_size" => text_size })
      visit_learn_with_notch(width: 1400, height: 430, inset: 59)

      resize(narrowest_uncollapsed_nav_width(height: 430), height: 430)

      expect(page).to have_link("Settings", visible: :visible)
      expect(rect("nav .brand")["left"]).to be_within(0.5).of(container_content["left"])
      expect(nav_row_overflow).to eq("row" => 0, "page" => 0, "past_gutter" => 0)
    end
  end

  [ [ 44, 44, "100" ], [ 59, 59, "100" ], [ 59, 59, "140" ], [ 59, 0, "100" ] ].each do |left, right, text_size|
    it "keeps the open menu's links and name field clear of a #{left}px left and #{right}px right notch, with its background to the edge, at #{text_size}% text" do
      user.update!(display_preferences: { "text_size" => text_size })
      resize(1400, height: 430)
      set_safe_area(left: left, right: right)
      visit_as(user)
      visit learn_path
      resize(narrowest_uncollapsed_nav_width(height: 430) - 10, height: 430)

      find("#nav-toggle").click
      expect(page).to have_link("Settings", visible: :visible)

      edges("nav .nav-links[data-open] a, nav .nav-links[data-open] .name-editor-input").each do |from_left, from_right|
        expect(from_left).to be >= [ left, 12 ].max - 0.5
        expect(from_right).to be >= [ right, 12 ].max - 0.5
      end
      expect(edges("nav .nav-links[data-open]").sole).to all(be_within(0.5).of(0))
      expect(sideways_overflow).to eq(0)
    end
  end
end
