require "rails_helper"

RSpec.describe "Dashboard on-demand generation", type: :system do
  it "generates and renders today's exercise for a fresh fake-provider user" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      # The :test queue adapter runs the enqueued job only inside perform_enqueued_jobs.
      perform_enqueued_jobs do
        visit_as(user)
      end

      # Waits on the page's own poll to reload; regex since CSS uppercases `.section-label` in the rendered text.
      expect(page).to have_content(/Code Review/i, wait: 10)

      # The judged path keeps only the kinds the plan chose, so which third and fourth render depends on the plan.
      exercise = DailyExercise.find_by!(user: user, date: Date.current)
      expect(exercise.active_section_keys.size).to be >= 2
      exercise.active_section_keys.each do |key|
        expect(page).to have_content(/#{Regexp.escape(I18n.t("sections.#{key}.name"))}/i)
      end
    end
  end
end
