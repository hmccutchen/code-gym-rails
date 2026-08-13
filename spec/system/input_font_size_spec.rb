require "rails_helper"

# A constant defined directly inside an RSpec.describe block is added to
# Object (RSpec class_evals the block), so it would collide with any other
# spec that names the same thing. Scoping it in a module keeps it out of the
# global namespace while still letting the Ruby assertion and the interpolated
# JS below share the single defined value.
module InputFontSizeSpecConstants
  IOS_ZOOM_THRESHOLD_PX = 16
end

# iOS auto-zooms a focused input whose computed font-size is under 16px, which
# shifts the layout and doesn't cleanly restore. Nothing else in the suite
# catches that: it is invisible on desktop and only manifests on a device.
#
# Deliberately walks the DOM instead of naming known controls. The regression
# that matters is a NEW input added below the floor by someone who never saw
# --input-font-size, and an enumerated list cannot catch one.
RSpec.describe "Focusable controls are large enough not to trigger iOS zoom", type: :system do
  let(:user)    { create_fake_provider_user }
  let(:weekday) { a_weekday }

  # Every control iOS would zoom on focus, with the size it renders at.
  # Not filtered to currently-visible elements: computed font-size is a
  # property of the control, not of whether it's on screen right now. A
  # control hidden behind a toggle (the duck-thread panel) gets focused the
  # moment the user opens that panel, and iOS zooms then — filtering by
  # visibility would measure the wrong thing.
  #
  # Returns the total control count alongside the undersized ones, so callers
  # can assert a floor: an empty undersized list is meaningless proof of
  # nothing if the walk quietly stopped finding half the controls it used to
  # (a renamed class, a feature moved behind a flag, a fixture that no longer
  # resolves to the section it used to).
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

  # FakeService returns every section kind at once and architecture wins
  # DailyPlan's third-slot precedence, so generation would never render the
  # challenge section — and textarea.code-answer only exists there.
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

  # Mirrors spec/requests/history_spec.rb's create_session_for: a submitted,
  # reviewed DailyResponse is the only way shared/_ai_review (and therefore
  # .self-explanation-input / .follow-up-input) ever enters the DOM.
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

      expect_no_undersized_controls(minimum_controls: 8)
    end
  end

  it "renders no undersized control on the login form" do
    visit login_path
    expect(page).to have_css(".form-field input", wait: 10)

    expect_no_undersized_controls(minimum_controls: 1)
  end

  it "renders no undersized control on a history entry's AI review, including follow-up/self-explanation inputs" do
    travel_to(weekday) do
      seed_reviewed_session
      visit_as(user)
      visit history_path
      expect(page).to have_css(".follow-up-input", wait: 10)
      expect(page).to have_css(".self-explanation-input")

      expect_no_undersized_controls(minimum_controls: 1)
    end
  end

  it "renders no undersized control on the setup page, including the timezone select" do
    setup_user = User.create!(email: "no-key-#{SecureRandom.hex(4)}@example.com", name: "No Key", time_zone: "UTC")
    visit_as(setup_user)
    visit setup_path
    expect(page).to have_css("#tz-select", wait: 10)

    expect_no_undersized_controls(minimum_controls: 1)
  end
end
