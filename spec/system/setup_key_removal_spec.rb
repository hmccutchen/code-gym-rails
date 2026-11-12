require "rails_helper"

RSpec.describe "Removing a stored key on Setup", type: :system do
  let(:user) do
    create_fake_provider_user.tap do |account|
      account.update!(api_keys: account.api_keys.merge("anthropic" => "sk-ant-api03-one", "openai" => "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq"),
                      provider: "anthropic",
                      key_saved_times: { "anthropic" => "2026-11-01T00:00:00Z", "openai" => "2026-11-02T00:00:00Z" })
    end
  end

  def open_setup(width: 1280)
    resize(width)
    visit_as(user)
    visit setup_path
    wait_for_js
  end

  def answer_confirm_with(accepted)
    page.execute_script("window.confirms = []; window.confirm = (message) => { window.confirms.push(message); return #{accepted}; };")
  end

  def confirms = page.evaluate_script("window.confirms")

  def remove_button(provider) = find_button("Remove #{provider} key")

  it "keeps the key when the confirmation is cancelled" do
    open_setup
    answer_confirm_with(false)

    remove_button("GPT").click

    expect(confirms).to eq([ "Remove your GPT key? You can add it again later." ])
    expect(page).to have_current_path(setup_path)
    expect(remove_button("GPT")).not_to be_disabled
    expect(user.reload.stored_providers).to include("openai")
  end

  it "removes the key in use from the keyboard and says which provider took over" do
    open_setup
    answer_confirm_with(true)

    page.execute_script("arguments[0].focus()", remove_button("Claude"))
    page.send_keys(:enter)

    expect(page).to have_css(".flash.notice", text: "Your Claude key was removed. GPT is now the provider in use.")
    expect(page).to have_no_button("Remove Claude key")
    expect(find("#saved-keys li", text: "GPT")).to have_css(".card-tag", text: "In use")
    expect(user.reload).to have_attributes(provider: "openai", stored_providers: %w[openai fake])
  end

  it "fits a phone: no sideways scroll, and each Remove button inside the card with a 44px target" do
    open_setup(width: 390)

    card = find("#saved-keys").ancestor(".card").rect
    buttons = all("#saved-keys button").map(&:rect)

    expect(sideways_overflow).to eq(0)
    expect(buttons.size).to eq(3)
    buttons.each do |button|
      expect(button["height"]).to be >= 44
      expect(button["left"]).to be >= card["left"]
      expect(button["right"]).to be <= card["right"]
    end
  end
end
