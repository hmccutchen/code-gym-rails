require "rails_helper"

# The checkbox persists through an inline listener that PATCHes /profile — no
# form submit, no Turbo. A request spec exercises that endpoint directly, so it
# stays green even if the listener is deleted or sends the wrong value; only a
# real browser round trip covers the wiring between the two.
RSpec.describe "Adaptive set size toggle", type: :system do
  let(:user) { create_fake_provider_user }

  # The click's fetch resolves independently of Capybara, so the assertion has
  # to wait on the write rather than on the DOM, which already shows the new
  # state optimistically.
  def preference_after_save(expected, timeout: 5)
    deadline = Time.current + timeout
    sleep 0.1 while user.reload.adaptive_set_size != expected && Time.current < deadline
    user.reload.adaptive_set_size
  end

  it "persists an unchecked box across a reload" do
    visit_as(user)
    visit setup_path

    expect(find("#adaptive-set-size")).to be_checked

    find("#adaptive-set-size").click

    expect(preference_after_save(false)).to be(false)

    visit setup_path

    expect(find("#adaptive-set-size")).not_to be_checked
  end
end
