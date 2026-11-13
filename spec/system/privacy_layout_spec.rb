require "rails_helper"

RSpec.describe "Privacy page layout", type: :system do
  [ 390, 1280 ].each do |width|
    it "fits a #{width}px screen signed out, with its text in a readable column" do
      resize(width)
      visit privacy_path

      expect(page).to have_css("h1", text: I18n.t("privacy.show.heading"))
      expect(sideways_overflow).to eq(0)
      expect(page.evaluate_script("document.querySelector('.privacy-page').getBoundingClientRect().width")).to be <= 640
    end
  end

  it "keeps its log in button 44px tall" do
    resize(390)
    visit privacy_path

    expect(page.evaluate_script("document.querySelector('.privacy-log-in a').getBoundingClientRect().height")).to be >= 44
  end
end
