require "rails_helper"

RSpec.describe "Parsons reorder controls", type: :system do
  it "shows no arrow buttons once drag is available" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_css("ol[data-parsons-blocks]", wait: 10)

      # data-sortable-done is set by the SortableJS module once drag is wired,
      # so waiting on it is what makes the absence assertion below meaningful
      # rather than merely early.
      expect(page).to have_css("ol[data-parsons-blocks][data-sortable-done]", wait: 10)
      expect(page).to have_no_css(".parsons-move-up")
      expect(page).to have_no_css(".parsons-move-down")
    end
  end
end
