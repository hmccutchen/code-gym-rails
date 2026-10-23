require "rails_helper"

RSpec.describe "Signing in with a password and an authenticator code", type: :system do
  let(:user) { enroll_two_factor(create_fake_provider_user) }

  def submit_login(code:)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: AuthHelpers::SPEC_PASSWORD
    fill_in "Authenticator or backup code", with: code
    click_button "Log in"
  end

  it "signs in with the current code" do
    submit_login(code: user.current_otp)

    expect(page).to have_current_path(root_path)
  end

  it "keeps a wrong code on the login page with one message for every kind of mistake" do
    submit_login(code: wrong_code_for(user.current_otp))

    expect(page).to have_content("Incorrect email, password or code.")
    expect(page).to have_field("Authenticator or backup code")
  end
end
