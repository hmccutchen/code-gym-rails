require "rails_helper"

# The whole move for an account from before passwords: emailed code, password, authenticator, then the app.
RSpec.describe "Moving an existing account to a password and an authenticator", type: :system do
  let(:user) { create_fake_provider_user }
  let(:password) { AuthHelpers::SPEC_PASSWORD }

  it "takes the account from an emailed code to a signed-in dashboard, and signs in with the new credentials after" do
    visit new_user_session_path
    click_link "Had an account before passwords? Sign in with an emailed code."
    fill_in "Work email *", with: user.email
    click_button "Send code"
    fill_in "6-digit code from the email", with: user.generate_login_code!
    click_button "Verify code"

    expect(page).to have_content("Choose a password")
    fill_in "Password (at least 12 characters)", with: password
    fill_in "Confirm password", with: password
    click_button "Save password"

    expect(page).to have_css(".otp-qr svg")
    secret = find(".otp-secret").text
    fill_in "6-digit code from the app", with: ROTP::TOTP.new(secret).now
    click_button "Turn on"

    expect(page).to have_css(".backup-codes li", count: SignInCredentials::BACKUP_CODE_COUNT)
    click_link "I've saved them. Continue"
    expect(page).to have_current_path(root_path)

    travel(31.seconds) do
      visit account_path
      click_button "Log out"
      fill_in "Email", with: user.email
      fill_in "Password", with: password
      fill_in "Authenticator or backup code", with: ROTP::TOTP.new(secret).now
      click_button "Log in"

      expect(page).to have_current_path(root_path)
    end
  end
end
