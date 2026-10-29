require "rails_helper"

RSpec.describe "Nav lined up with the page column below 900px", type: :system do
  let(:user) { create_fake_provider_user }

  [ 800, 844, 899 ].each do |width|
    it "starts the brand and ends the last link with the page content at #{width}px" do
      resize(width, height: 800)
      visit_as(user)
      visit history_path

      expect(page).to have_link("Settings", visible: :visible)
      expect_nav_on_the_column
      expect(nav_row_overflow).to eq("row" => 0, "page" => 0, "past_gutter" => 0)
    end
  end

  [ 810, 844, 899 ].each do |width|
    it "shows the menu button with the brand on the column at #{width}px and 112% text, where the capped row is under 42em" do
      user.update!(display_preferences: { "text_size" => "112" })
      resize(width, height: 800)
      visit_as(user)
      visit history_path

      expect(page).to have_css("#nav-toggle", visible: :visible)
      expect(rect("nav .brand")["left"]).to be_within(0.5).of(container_content["left"])
    end
  end

  it "keeps the brand at the phone gutter where the window is narrower than the column" do
    resize(760, height: 800)
    visit_as(user)
    visit history_path

    expect(edges("nav .brand").sole.first).to be_within(0.5).of(24)
    expect_nav_on_the_column
  end

  [ [ "112", 44, 16 ], [ "100", 0, 18 ], [ "100", 0, 19 ], [ "112", 0, 17 ], [ "100", 44, 16 ] ].each do |text_size, inset, default_font|
    it "shows the menu button wherever the row's links wouldn't fit, at #{text_size}% text, a #{inset}px notch and a #{default_font}px browser font" do
      user.update!(display_preferences: { "text_size" => text_size })
      resize(899, height: 430)
      set_safe_area(left: inset, right: inset)
      set_default_font_size(default_font)
      visit_as(user)
      visit history_path

      overflowing = (800..899).select { |width|
        resize(width, height: 430)
        page.has_no_css?("#nav-toggle", visible: :visible, wait: 0) && nav_row_overflow != { "row" => 0, "page" => 0, "past_gutter" => 0 }
      }
      expect(overflowing).to eq([])
    end
  end
end
