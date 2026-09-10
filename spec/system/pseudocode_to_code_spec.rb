require "rails_helper"

# The critique round is inline JavaScript talking to a JSON endpoint, so request
# specs execute none of it. These cover the parts that only exist in the
# browser: the round button, its one-shot disabling, and — since the translate
# button that used to gate this section is gone — that submit is now gated on
# nothing but the ratings, exactly like every other kind.
RSpec.describe "Pseudocode to code", type: :system, with_csrf: true do
  # The inline script reads the CSRF meta tag before every fetch, and
  # allow_forgery_protection off (config/environments/test.rb) blanks it.
  # See spec/support/csrf_helper.rb.

  # Created up front rather than letting the dashboard generate on demand:
  # FakeService returns every kind at once and plan_review wins the fourth slot
  # by precedence, so a generated day never presents this section.
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

  # The section offers nothing to press before submitting except the critique,
  # so a written plan is submittable the moment every section is rated — the
  # translate gate this used to assert in both directions is gone with the
  # button, and the translation happens inside the review instead.
  it "gates submit on the ratings alone, written plan or not" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      open_dashboard(user)

      expect(page).to have_button("Submit answers →", disabled: true)
      expect(page).not_to have_button("Translate to code")

      all("button.rating-btn[data-rating='right_level']").each(&:click)
      expect(page).to have_button("Submit answers →", disabled: false)

      write_plan(PLAN)
      expect(page).to have_button("Submit answers →", disabled: false)
    end
  end

  # The translation is the review's job now, so this is the only place the
  # generated code can appear — and it has to appear where the review does,
  # captioned, rather than reading as a model answer.
  it "shows the code the review translated the plan into" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      open_dashboard(user)
      write_plan(PLAN)
      all("button.rating-btn[data-rating='right_level']").each(&:click)

      click_button "Submit answers →"

      expect(page).to have_content("def merge_ranges", wait: 20)
      expect(page).to have_content(/implemented literally — gaps and all/i)

      round = user.daily_responses.find_by(date: Date.current).pseudocode_round("pseudocode_to_code")
      expect(round["translated_from"]).to eq(PLAN)
    end
  end
end
