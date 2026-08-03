# spec/system/dashboard_generation_spec.rb
require "rails_helper"

RSpec.describe "Dashboard on-demand generation", type: :system do
  it "generates and renders today's exercise for a fresh fake-provider user" do
    user = create_fake_provider_user
    monday = Date.current.beginning_of_week(:monday)

    travel_to(monday) do
      # DashboardController#show enqueues GenerateDailyExercisesJob on a
      # weekday when no exercise exists yet; :test queue_adapter means it
      # won't actually run unless we ask it to.
      perform_enqueued_jobs do
        visit_as(user)
      end

      # The initial render still shows the "generating" placeholder (the job
      # ran synchronously above, but @exercise was already looked up as nil
      # before the job was enqueued) — the page's own poll script picks up
      # the now-ready state and reloads. default_max_wait_time (10s, Task 5)
      # comfortably covers the poll's first 3s tick.
      #
      # Regex, not a literal string: these labels render inside
      # `.section-label`, which is CSS `text-transform: uppercase` — the
      # Playwright driver matches on the rendered (uppercased) text, so a
      # literal "Code Review" would fail. Case-insensitive regex sidesteps
      # both the DOM casing and this rendering detail.
      expect(page).to have_content(/Code Review/i, wait: 10)
      expect(page).to have_content(/Pattern of the Month/i)
      expect(page).to have_content(/Architecture Decision/i)
    end
  end
end
