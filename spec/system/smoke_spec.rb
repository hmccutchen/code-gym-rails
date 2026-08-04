require "rails_helper"

# Intentionally kept alongside the feature specs: a minimal "is the driver
# even working" canary. If this fails, the problem is Capybara/Playwright
# setup itself, not app behavior — check here first before debugging a
# failure in dashboard_generation_spec.rb or the others.
RSpec.describe "System test driver", type: :system do
  it "renders a real page in a real browser" do
    fake_user = create_fake_provider_user
    visit_as(fake_user)

    expect(page).to have_current_path(root_path)
  end
end
