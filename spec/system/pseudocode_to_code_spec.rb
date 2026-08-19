require "rails_helper"

# The pseudocode rounds are inline JavaScript talking to two JSON endpoints, so
# request specs execute none of it. These cover the parts that only exist in the
# browser: the two round buttons, their one-shot disabling, the rendered code,
# and the submit gate — which is the one place this kind can block finishing a
# set, so it needs to be exercised in both directions.
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

  it "critiques a plan, then translates it faithfully, each exactly once" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      open_dashboard(user)
      write_plan(PLAN)

      click_button "Check my plan"
      expect(page).to have_content(/never says what happens when the input list is empty/i, wait: 10)
      expect(page).to have_button("Check my plan", disabled: true)

      click_button "Translate to code"
      expect(page).to have_content("def merge_ranges", wait: 10)
      expect(page).to have_content(/implemented literally — gaps and all/i)
      expect(page).to have_button("Translate to code", disabled: true)

      # Faithfulness, observed rather than asserted about the prompt: the canned
      # plan omits the empty-input case and the generated code omits it too. A
      # translation that "helpfully" added a guard would fail here.
      expect(page).not_to have_content(".empty?")

      round = user.daily_responses.find_by(date: Date.current).pseudocode_round("pseudocode_to_code")
      expect(round["translated_from"]).to eq(PLAN)
    end
  end

  it "blocks submit on a written-but-untranslated plan, and never on an untouched one" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      open_dashboard(user)
      all("button.rating-btn[data-rating='right_level']").each(&:click)

      # Untouched section: skippable exactly like every other kind.
      expect(page).to have_button("Submit answers →", disabled: false)
      expect(page).not_to have_content(/Translate your pseudocode to code before submitting/i)

      write_plan(PLAN)
      expect(page).to have_content(/Translate your pseudocode to code before submitting/i)
      expect(page).to have_button("Submit answers →", disabled: true)

      click_button "Translate to code"
      expect(page).to have_content("def merge_ranges", wait: 10)
      expect(page).to have_button("Submit answers →", disabled: false)
    end
  end

  # The gate must never trap someone behind an outage they cannot fix from this
  # page. Every other gate in this app is satisfiable without a provider.
  it "releases the gate when the provider refuses the translation" do
    user = create_fake_provider_user
    allow_any_instance_of(FakeService).to receive(:translate_pseudocode)
      .and_raise(AiService::Error, "The AI provider is unavailable.")

    travel_to(a_weekday) do
      open_dashboard(user)
      all("button.rating-btn[data-rating='right_level']").each(&:click)
      write_plan(PLAN)

      expect(page).to have_button("Submit answers →", disabled: true)

      click_button "Translate to code"

      expect(page).to have_content(/still submit without translating/i, wait: 10)
      expect(page).to have_button("Submit answers →", disabled: false)
      expect(page).not_to have_css("[data-pseudocode-code] pre")
    end
  end
end
