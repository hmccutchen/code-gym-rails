require "rails_helper"

RSpec.describe "Returning to a review that is still running", type: :system do
  it "shows the review as running, then the finished review once the claim is released" do
    user = create_fake_provider_user
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } }
    )
    daily_response = DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20 }, submitted_at: Time.current, reviewing_since: Time.current
    )

    visit_as(user)
    expect(page).to have_content(I18n.t("review.in_progress.hint"))
    expect(page).to have_no_selector("form.review-form")

    daily_response.update!(reviewing_since: nil,
                           ai_review: { "code_review" => { "rating" => "solid", "correct" => "You found the bug." } })

    expect(page).to have_content("You found the bug.")
    expect(page).to have_no_content(I18n.t("review.in_progress.hint"))
  end
end
