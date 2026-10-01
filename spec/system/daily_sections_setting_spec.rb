require "rails_helper"

# The radios persist through an inline listener that PATCHes /profile — no
# form submit, no Turbo. A request spec exercises that endpoint directly, so it
# stays green even if the listener is deleted or sends the wrong value; only a
# real browser round trip covers the wiring between the two.
RSpec.describe "Daily sections setting", type: :system do
  let(:user) { create_fake_provider_user }

  # The click's fetch resolves independently of Capybara, so the assertion has
  # to wait on the write rather than on the DOM, which already shows the new
  # choice.
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
