require "rails_helper"

# The menu is CSS collapse plus an inline toggle script, so a request spec sees
# every link in the markup whether or not the button works. What is worth
# pinning is the visible behavior at a phone width: the destinations are out of
# the row until the button is pressed, and they come back.
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
    # A real press below the open panel and to the right of the container's
    # text column, where no link's rendered width reaches. The path assertion
    # is what keeps it honest: a press that navigated would also have closed
    # the menu, so a mis-aimed coordinate fails rather than passes quietly.
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
end
