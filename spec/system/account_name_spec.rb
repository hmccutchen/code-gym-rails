require "rails_helper"

RSpec.describe "Editing the name on the Account page", type: :system do
  it "saves a name typed into the Account page's Name field, wherever the nav hides its own field" do
    user = create_fake_provider_user(name: "Old Name")
    resize(1280, height: 800)
    visit_as(user)
    visit account_path

    fill_in "Name", with: "New Name"
    find("h1").click

    expect(page).to have_css("#account-name-status", text: I18n.t("profile.name.saved"))
    expect(user.reload.name).to eq("New Name")
    visit account_path
    expect(page).to have_field("Name", with: "New Name")
  end
end
