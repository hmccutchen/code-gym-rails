require "rails_helper"

# The selected rating is drawn with a filled button. aria-pressed has to follow
# the same state, or a screen reader hears three identical buttons.
RSpec.describe "Rating buttons", type: :system do
  let(:user) { create_fake_provider_user }

  def pressed(field)
    all(%(.rating-row[data-rating-for="#{field}"] button)).to_h { |b| [ b["data-rating"], b["aria-pressed"] ] }
  end

  it "names each group and moves aria-pressed with the selection" do
    travel_to(a_weekday) do
      visit_with_todays_set(user)

      expect(page).to have_css(%(.rating-row[data-rating-for="code_review"][role="group"][aria-label="How hard was Code Review for you?"]))
      expect(pressed("code_review")).to eq("too_easy" => "false", "right_level" => "false", "too_hard" => "false")

      find(%(button[data-rating-for="code_review"][data-rating="too_hard"])).click
      expect(pressed("code_review")).to eq("too_easy" => "false", "right_level" => "false", "too_hard" => "true")

      find(%(button[data-rating-for="code_review"][data-rating="right_level"])).click
      expect(pressed("code_review")).to eq("too_easy" => "false", "right_level" => "true", "too_hard" => "false")
    end
  end

  it "marks a rating stored before the page loaded as pressed" do
    travel_to(a_weekday) do
      GenerateDailyExercisesJob.perform_now(user_id: user.id)
      exercise = user.daily_exercises.last
      DailyResponse.create!(user: user, daily_exercise: exercise, date: exercise.date,
                            answers: {}, section_ratings: { "code_review" => "too_easy" })

      visit_as(user)

      expect(page).to have_css(%(button[data-rating-for="code_review"][data-rating="too_easy"].active[aria-pressed="true"]))
      expect(pressed("code_review")).to eq("too_easy" => "true", "right_level" => "false", "too_hard" => "false")
    end
  end
end
