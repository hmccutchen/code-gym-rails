require "rails_helper"

# The reason #verify renders instead of redirecting: the tab that requested
# the link is already polling and will move itself into the app off the shared
# cookie. Only a real browser with two real windows can show that the handoff
# happens and that the link tab stays put.
RSpec.describe "Magic link login across two tabs", type: :system do
  let(:user) { create_fake_provider_user }

  it "moves the requesting tab into the app while the link tab stays terminal" do
    visit login_path
    fill_in "Work email", with: user.email
    click_button "Send magic link →"
    expect(page).to have_content("Check your email")

    requesting_tab = page.current_window
    link_tab = open_new_window

    within_window(link_tab) do
      visit verify_auth_path(token: user.generate_login_token!)

      expect(page).to have_content("You're logged in")
      expect(page).to have_content("close this tab")
      expect(page).to have_current_path(verify_auth_path, ignore_query: true)
    end

    # The poll runs on a 3s cycle, so this needs longer than the default wait.
    within_window(requesting_tab) do
      expect(page).to have_current_path(root_path, wait: 20)
    end

    # Still terminal — the requesting tab moving did not drag this one along.
    within_window(link_tab) do
      expect(page).to have_current_path(verify_auth_path, ignore_query: true)
    end
  end

  it "lets a user with no requesting tab continue into the app" do
    visit verify_auth_path(token: user.generate_login_token!)
    click_link "Continue to today's set →"

    expect(page).to have_current_path(root_path)
  end
end
