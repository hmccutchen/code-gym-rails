require "rails_helper"

RSpec.describe "System test driver", type: :system do
  it "renders a real page in a real browser" do
    fake_user = create_fake_provider_user
    visit_as(fake_user)

    expect(page).to have_current_path(root_path)
  end
end
