require "rails_helper"

# The code path is now the only way in, and it is the one flow a unit spec
# cannot fully vouch for: it spans two requests in one browser, and its
# security rests on the second one reading the email from the session rather
# than the page.
RSpec.describe "Logging in with an emailed code", type: :system do
  let(:user) { create_fake_provider_user }

  it "signs a user in from the code they were emailed" do
    visit login_path
    fill_in "Work email *", with: user.email
    click_button "Send code →"

    expect(page).to have_content("Enter the 6-digit code")

    fill_in "6-digit code from the email", with: user.generate_login_code!
    click_button "Verify code →"

    expect(page).to have_current_path(root_path)
  end

  it "keeps the request form on the page so a new code is always one click away" do
    visit login_path
    fill_in "Work email *", with: user.email
    click_button "Send code →"

    expect(page).to have_field("6-digit code from the email")
    expect(page).to have_field("Work email *")
    expect(page).to have_button("Send code →")
  end

  it "rejects a wrong code without losing the page" do
    visit login_path
    fill_in "Work email *", with: user.email
    click_button "Send code →"

    fill_in "6-digit code from the email", with: "000000"
    click_button "Verify code →"

    # The email carries no link to point a locked-out user at, so the
    # rejection has to send them back to the form instead.
    expect(page).to have_content("Incorrect or expired code. Try again, or request a new one below.")
    expect(page).to have_field("6-digit code from the email")
  end
end
