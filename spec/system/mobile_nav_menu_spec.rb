require "rails_helper"

# A request spec sees every link in the markup, so this pins visible behavior at phone width.
RSpec.describe "Mobile nav menu", type: :system do
  let(:phone_width) { 375 }
  let(:desktop_width) { 1024 }

  def menu_button
    find("#nav-toggle")
  end

  it "keeps the destinations out of the row until the button opens them" do
    user = create_fake_provider_user

    page.current_window.resize_to(phone_width, 800)
    visit_as(user)
    visit learn_path

    expect(page).to have_no_link("History", visible: :visible)
    expect(menu_button[:"aria-expanded"]).to eq("false")

    menu_button.click

    expect(page).to have_link("History", visible: :visible)
    expect(page).to have_link("Account", visible: :visible)
    expect(menu_button[:"aria-expanded"]).to eq("true")
  end

  it "closes on a second press, on Escape, and on a click outside it" do
    user = create_fake_provider_user

    page.current_window.resize_to(phone_width, 800)
    visit_as(user)
    visit learn_path

    menu_button.click
    expect(page).to have_link("History", visible: :visible)
    menu_button.click
    expect(page).to have_no_link("History", visible: :visible)

    menu_button.click
    expect(page).to have_link("History", visible: :visible)
    find("body").send_keys(:escape)
    expect(page).to have_no_link("History", visible: :visible)
    expect(menu_button[:"aria-expanded"]).to eq("false")

    menu_button.click
    expect(page).to have_link("History", visible: :visible)
    # Aimed where no link reaches; the path assertion fails a mis-aimed press that navigated instead.
    page.driver.with_playwright_page { |pw| pw.mouse.click(365, 600) }
    expect(page).to have_no_link("History", visible: :visible)
    expect(page).to have_current_path(learn_path)
  end

  it "leaves the wide layout alone: links in the row, no button" do
    user = create_fake_provider_user

    page.current_window.resize_to(desktop_width, 800)
    visit_as(user)
    visit learn_path

    expect(page).to have_link("History", visible: :visible)
    expect(page).to have_no_css("#nav-toggle", visible: :visible)
  end

  [ "100", "140" ].each do |text_size|
    it "fits every link in the row just above the width where it collapses, at #{text_size}% text" do
      user = create_fake_provider_user
      user.update!(display_preferences: { "text_size" => text_size })
      visit_as(user)
      visit learn_path

      narrowest_row = (320..1400).step(10).find { |width|
        page.current_window.resize_to(width, 800)
        page.has_no_css?("#nav-toggle", visible: :visible, wait: 0)
      }
      page.current_window.resize_to(narrowest_row, 800)

      expect(page).to have_link("Settings", visible: :visible)
      overflow = page.evaluate_script(<<~JS)
        [document.querySelector("nav .inner"), document.documentElement].map(el => el.scrollWidth - el.clientWidth)
      JS
      expect(overflow).to eq([ 0, 0 ])
    end
  end
end
