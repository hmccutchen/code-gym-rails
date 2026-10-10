require "rails_helper"

# A constant in an RSpec.describe block lands on Object, so this module keeps it out of the global namespace.
module InputFontSizeSpecConstants
  IOS_ZOOM_THRESHOLD_PX = 16
end

# Walks the whole DOM so a new input added below iOS's 16px zoom threshold is caught, which a fixed list can't do.
RSpec.describe "Focusable controls are large enough not to trigger iOS zoom", type: :system do
  let(:user)    { create_fake_provider_user }
  let(:weekday) { a_weekday }

  # Includes hidden controls (iOS zooms when they're focused) and returns the total so callers can assert a floor.
  def scan_controls
    page.evaluate_script(<<~JS)
      (() => {
        const controls = Array.from(
          document.querySelectorAll("textarea, select, input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button])")
        ).map(el => ({
          id: el.id || el.name || el.className || el.tagName.toLowerCase(),
          size: parseFloat(getComputedStyle(el).fontSize)
        }));
        return {
          total: controls.length,
          undersized: controls.filter(c => c.size < #{InputFontSizeSpecConstants::IOS_ZOOM_THRESHOLD_PX})
        };
      })();
    JS
  end

  def expect_no_undersized_controls(minimum_controls:)
    result = scan_controls
    expect(result["total"]).to be >= minimum_controls,
      "expected at least #{minimum_controls} focusable controls on the page, " \
      "found only #{result['total']} — the set of controls this guard covers " \
      "appears to have shrunk (a renamed class, a moved feature, or a fixture " \
      "that no longer renders the section it used to)"

    expect(result["undersized"]).to be_empty
  end

  # Architecture wins the third slot, so generation never renders challenge, the only home of textarea.code-answer.
  def seed_challenge_exercise
    DailyExercise.create!(
      user: user,
      date: weekday.to_date,
      language: "ruby_rails",
      generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "challenge"   => { "title" => "C", "question" => "q", "starter_code" => "def x; end", "concept" => "n_plus_one" }
      }
    )
  end

  # A submitted, reviewed response is the only way shared/_ai_review and .follow-up-input reach the DOM.
  def seed_reviewed_session
    exercise = DailyExercise.create!(
      user: user, date: weekday.to_date, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern"     => { "title" => "P", "question" => "q" },
        "challenge"   => { "question" => "q" }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: weekday.to_date,
      answers: { "code_review" => "Answer with plenty of substance" },
      submitted_at: Time.current,
      section_ratings: { "code_review" => "right_level" },
      ai_review: { "code_review" => { "rating" => "solid", "correct" => "Spotted the issue" } }
    )
  end

  it "renders no undersized control on the dashboard answer form" do
    travel_to(weekday) do
      seed_challenge_exercise
      visit_as(user)
      expect(page).to have_css("textarea.answer", wait: 10)

      expect_no_undersized_controls(minimum_controls: 7)
    end
  end

  it "renders no undersized control on the login form" do
    visit login_path
    expect(page).to have_css(".form-field input", wait: 10)

    expect_no_undersized_controls(minimum_controls: 1)
  end

  it "renders no undersized control on a history entry's AI review, including the follow-up input" do
    travel_to(weekday) do
      seed_reviewed_session
      visit_as(user)
      visit history_path
      expect(page).to have_css(".follow-up-input", wait: 10)

      expect_no_undersized_controls(minimum_controls: 1)
    end
  end

  it "renders no undersized control on the setup page, including the timezone select" do
    setup_user = User.create!(email: "no-key-#{SecureRandom.hex(4)}@example.com", name: "No Key", time_zone: "UTC",
                              learning_track: "none")
    visit_as(setup_user)
    visit setup_path
    expect(page).to have_css("#tz-select", wait: 10)

    expect_no_undersized_controls(minimum_controls: 1)
  end
end
