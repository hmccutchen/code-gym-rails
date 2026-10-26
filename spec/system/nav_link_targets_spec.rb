require "rails_helper"

RSpec.describe "Nav link targets", type: :system do
  [ 768, 1024, 1280 ].each do |width|
    it "makes every link in the row at least 44px tall at #{width}px" do
      user = create_fake_provider_user

      resize(width, height: 800)
      visit_as(user)
      visit learn_path

      expect(page).to have_link("Settings", visible: :visible)
      heights = rects("nav .nav-links a").reject { |r| r["width"].zero? }.map { |r| r["height"] }
      expect(heights.size).to be >= 5
      expect(heights).to all(be >= 44)
    end
  end
end
