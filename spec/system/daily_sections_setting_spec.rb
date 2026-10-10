require "rails_helper"

# Only a real browser round trip covers the listener that PATCHes /profile; a request spec stays green without it.
RSpec.describe "Daily sections setting", type: :system do
  let(:user) { create_fake_provider_user }

  # Waits on the write, not the DOM: the fetch resolves independently of Capybara.
  def count_after_save(expected, timeout: 5)
    deadline = Time.current + timeout
    sleep 0.1 while user.reload.daily_section_count != expected && Time.current < deadline
    user.reload.daily_section_count
  end

  it "persists a fixed count across a reload, then goes back to Automatic" do
    visit_as(user)
    visit setup_path

    within("#daily-sections") do
      expect(find_field("Automatic")).to be_checked
      choose "2"
    end

    expect(count_after_save(2)).to eq(2)

    visit setup_path

    within("#daily-sections") do
      expect(find_field("2")).to be_checked
      choose "Automatic"
    end

    expect(count_after_save(nil)).to be_nil

    visit setup_path

    expect(within("#daily-sections") { find_field("Automatic") }).to be_checked
  end
end
