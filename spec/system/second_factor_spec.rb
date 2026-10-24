require "rails_helper"

RSpec.describe "Authenticator app", type: :system do
  let(:user) { create_fake_provider_user }

  def setup_key
    find(".setup-key").text.delete(" ")
  end

  def turn_on_authenticator
    visit account_authenticator_path
    secret = setup_key
    fill_in "Enter the 6-digit code your app shows", with: current_totp(secret)
    click_button "Turn on"
    expect(page).to have_css(".recovery-code-list li", count: 10)
    [ secret, all(".recovery-code-list li").map(&:text) ]
  end

  def sign_in_through_second_step(code)
    visit_as(user)
    expect(page).to have_current_path(second_factor_challenge_path)
    fill_in "Code from your authenticator app, or a recovery code", with: code
    click_button "Verify"
  end

  def sign_out
    visit account_path
    click_button "Log out"
    expect(page).to have_current_path(login_path)
  end

  def selected_text
    page.evaluate_script("window.getSelection().toString()")
  end

  it "signs an account with the authenticator on in with its email and an authenticator code, and no emailed code" do
    secret, _codes = enroll_second_factor(user)

    visit login_path
    fill_in "Work email *", with: user.email
    click_button "Send code"

    expect(page).to have_current_path(second_factor_challenge_path)
    expect(page).to have_no_field("6-digit code from the email")
    fill_in "Code from your authenticator app, or a recovery code", with: current_totp(secret)
    click_button "Verify"

    expect(page).to have_current_path(root_path)
  end

  it "shows the recovery codes and stays signed in on a double tap of Turn on" do
    visit_as(user)
    visit account_authenticator_path
    fill_in "Enter the 6-digit code your app shows", with: current_totp(setup_key)
    wait_for_js
    page.execute_script(<<~JS)
      const button = [...document.querySelectorAll("input[type=submit]")].find((b) => b.value === "Turn on");
      button.click();
      setTimeout(() => button.click(), 20);
    JS

    expect(page).to have_css(".recovery-code-list li", count: 10)
    visit account_path
    expect(page).to have_current_path(account_path)
  end

  it "turns on, signs in through the second step with each kind of code, and turns off" do
    visit_as(user)
    secret, codes = turn_on_authenticator
    expect(page).to have_text("This is the only time they are shown")

    sign_out
    sign_in_through_second_step(current_totp(secret, at: User::TOTP_INTERVAL.seconds.from_now))
    expect(page).to have_current_path(root_path)

    sign_out
    sign_in_through_second_step(codes.first)
    expect(page).to have_text("You have 9 recovery codes left.")

    visit account_path
    fill_in "disable_otp_code", with: codes.second
    click_button "Turn off"
    expect(page).to have_text("The authenticator app is off.")
    expect(user.reload.two_factor_enabled?).to be(false)
  end

  it "selects the setup key for copying by hand when the clipboard is missing" do
    visit_as(user)
    visit account_authenticator_path
    wait_for_js
    page.execute_script("Object.defineProperty(navigator, 'clipboard', { value: undefined, configurable: true })")

    click_button "Copy"

    expect(page).to have_text("Selected. Copy it with your device's copy command.")
    expect(selected_text.delete(" ")).to eq(setup_key)
  end

  it "selects the setup key for copying by hand when the clipboard refuses the write" do
    visit_as(user)
    visit account_authenticator_path
    wait_for_js
    page.execute_script(<<~JS)
      Object.defineProperty(navigator, "clipboard", {
        value: { writeText: () => Promise.reject(new Error("denied")) }, configurable: true
      })
    JS

    click_button "Copy"

    expect(page).to have_text("Selected. Copy it with your device's copy command.")
    expect(selected_text.delete(" ")).to eq(setup_key)
  end
end
