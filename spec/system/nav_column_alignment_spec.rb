require "rails_helper"

RSpec.describe "Nav lined up with the page column below 900px", type: :system do
  let(:user) { create_fake_provider_user }

  def expect_nav_on_the_column
    content = container_content
    expect(rect("nav .brand")["left"]).to be_within(0.5).of(content["left"])
    expect(rects("nav .nav-links a").last["right"]).to be_within(0.5).of(content["right"])
  end

  [ [ "100", [ 800, 844, 899 ] ], [ "112", [ 810, 844, 899 ] ] ].each do |text_size, widths|
    widths.each do |width|
      it "starts the brand and ends the last link with the page content at #{width}px, #{text_size}% text" do
        user.update!(display_preferences: { "text_size" => text_size })
        resize(width, height: 800)
        visit_as(user)
        visit history_path

        expect(page).to have_link("Settings", visible: :visible)
        expect_nav_on_the_column
        expect(nav_row_overflow).to eq("row" => 0, "page" => 0, "past_gutter" => 0)
      end
    end
  end

  it "keeps the brand at the phone gutter where the window is narrower than the column" do
    resize(760, height: 800)
    visit_as(user)
    visit history_path

    expect(edges("nav .brand").sole.first).to be_within(0.5).of(24)
    expect_nav_on_the_column
  end
end
