require "rails_helper"

# iOS auto-zooms a focused input whose computed font-size is under 16px, which
# shifts the layout and doesn't cleanly restore. Nothing else in the suite
# catches that: it is invisible on desktop and only manifests on a device.
#
# Deliberately walks the DOM instead of naming known controls. The regression
# that matters is a NEW input added below the floor by someone who never saw
# --input-font-size, and an enumerated list cannot catch one.
RSpec.describe "Focusable controls are large enough not to trigger iOS zoom", type: :system do
  IOS_ZOOM_THRESHOLD_PX = 16

  let(:user)    { create_fake_provider_user }
  let(:weekday) { a_weekday }

  # Every control iOS would zoom on focus, with the size it renders at.
  # Not filtered to currently-visible elements: computed font-size is a
  # property of the control, not of whether it's on screen right now. A
  # control hidden behind a toggle (the duck-thread panel, a history
  # review's follow-up/self-explanation inputs) gets focused the moment
  # the user opens that panel, and iOS zooms then — filtering by
  # visibility would measure the wrong thing.
  def undersized_controls
    page.evaluate_script(<<~JS)
      Array.from(
        document.querySelectorAll("textarea, select, input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button])")
      )
        .map(el => ({
          id: el.id || el.name || el.className || el.tagName.toLowerCase(),
          size: parseFloat(getComputedStyle(el).fontSize)
        }))
        .filter(c => c.size < #{IOS_ZOOM_THRESHOLD_PX});
    JS
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

  it "renders no undersized control on the dashboard answer form" do
    travel_to(weekday) do
      seed_challenge_exercise
      visit_as(user)
      expect(page).to have_css("textarea.answer", wait: 10)

      expect(undersized_controls).to be_empty
    end
  end

  it "renders no undersized control on the login form" do
    visit login_path
    expect(page).to have_css(".form-field input", wait: 10)

    expect(undersized_controls).to be_empty
  end
end
