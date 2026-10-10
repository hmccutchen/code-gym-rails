require "rails_helper"

# fetch follows the expired session's login redirect, so the reply is a 200 the page must not start polling on.
RSpec.describe "Learn write-up after the session expired", type: :system, with_csrf: true do
  it "says the session expired instead of polling the login page" do
    user = create_fake_provider_user
    user.update!(language: "ruby_rails")
    visit_as(user)
    visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

    page.execute_script(<<~JS)
      window.fetch = () => Promise.resolve(Object.defineProperty(
        new Response("<html><body>Log in</body></html>", { status: 200, headers: { "Content-Type": "text/html" } }),
        "redirected", { value: true }
      ));
    JS
    click_button I18n.t("learn.write_guide")

    expect(page).to have_css(".learn-status", text: I18n.t("server_message.signed_out"))
    expect(page).to have_button(I18n.t("learn.write_guide"), disabled: false)
  end
end
