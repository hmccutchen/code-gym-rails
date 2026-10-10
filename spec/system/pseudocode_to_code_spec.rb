require "rails_helper"

# The critique round is inline JavaScript, so request specs execute none of it.
RSpec.describe "Pseudocode to code", type: :system, with_csrf: true do
  # with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).

  # Created up front: plan_review wins the fourth slot by precedence, so a generated day never shows this section.
  def create_exercise_for(user)
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review"        => FakeService::EXERCISE_PROBLEM_SET["code_review"],
        "pattern"            => FakeService::EXERCISE_PROBLEM_SET["pattern"],
        "challenge"          => FakeService::EXERCISE_PROBLEM_SET["challenge"],
        "pseudocode_to_code" => FakeService::EXERCISE_PROBLEM_SET["pseudocode_to_code"]
      }
    )
  end

  def open_dashboard(user)
    create_exercise_for(user)
    visit_as(user)
    expect(page).to have_content(/Pseudocode to Code/i, wait: 10)
  end

  def write_plan(text)
    find('textarea[data-field="pseudocode_to_code"]').fill_in(with: text)
  end

  PLAN = "sort the ranges by start, then walk them merging any that overlap".freeze

  it "critiques a plan exactly once" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      open_dashboard(user)
      write_plan(PLAN)

      click_button "Check my plan"
      expect(page).to have_content(/never says what happens when the input list is empty/i, wait: 10)
      expect(page).to have_button("Check my plan", disabled: true)
    end
  end

  it "enables submit once the written plan is rated, with no translate or critique step in the way" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      open_dashboard(user)

      expect(page).to have_button("Submit answers", disabled: true)
      expect(page).not_to have_button("Translate to code")

      write_plan(PLAN)
      expect(page).to have_button("Submit answers", disabled: true)

      rate_section("pseudocode_to_code")
      expect(page).to have_button("Submit answers", disabled: false)
    end
  end

  # The review is the only place the translated code appears, captioned so it doesn't read as a model answer.
  it "shows the code the review translated the plan into" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      open_dashboard(user)
      write_plan(PLAN)
      all("button.rating-btn[data-rating='right_level']").each(&:click)

      click_button "Submit answers"

      expect(page).to have_content("def merge_ranges", wait: 20)
      expect(page).to have_content(/implemented literally — gaps and all/i)

      round = user.daily_responses.find_by(date: Date.current).pseudocode_round("pseudocode_to_code")
      expect(round["translated_from"]).to eq(PLAN)
    end
  end
end
