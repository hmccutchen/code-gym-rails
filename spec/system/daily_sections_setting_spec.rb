require "rails_helper"

# Only a real browser round trip covers the listener that PATCHes /profile; a request spec stays green without it.
RSpec.describe "Daily sections setting", type: :system do
  let(:user) { create_fake_provider_user }

  # Waits on the write, not the DOM: the fetch resolves independently of Capybara.
  def count_after_save(expected)
    wait_for { user.reload.daily_section_count == expected }
    user.reload.daily_section_count
  end

  it "persists a fixed count across a reload, then goes back to Automatic" do
    visit_as(user)
    visit setup_path

    within("#daily-sections") do
      expect(find_field("Automatic", visible: :all)).to be_checked
      choose "2", allow_label_click: true
    end

    expect(count_after_save(2)).to eq(2)

    visit setup_path

    within("#daily-sections") do
      expect(find_field("2", visible: :all)).to be_checked
      choose "Automatic", allow_label_click: true
    end

    expect(count_after_save(nil)).to be_nil

    visit setup_path

    expect(within("#daily-sections") { find_field("Automatic", visible: :all) }).to be_checked
  end

  it "saves a count from a tap on its segment" do
    visit_as(user)
    visit setup_path

    find("#daily-sections .segment", text: "3").click

    expect(count_after_save(3)).to eq(3)
  end
end
