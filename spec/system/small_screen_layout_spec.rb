require "rails_helper"

# Reflow (WCAG 1.4.10) and target size only show up in a real layout: a
# request spec sees the same markup whether or not a row fits its screen.
RSpec.describe "Small screen layout", type: :system do
  def resize(width)
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: width, height: 844) }
  end

  def page_width
    page.evaluate_script("document.documentElement.scrollWidth")
  end

  LARGEST = { "text_size" => "140", "line_spacing" => "loose", "font" => "atkinson" }.freeze

  # The WCAG 1.4.12 text-spacing override, the harshest case these pages meet.
  def apply_text_spacing
    page.execute_script(<<~JS)
      const style = document.createElement("style");
      style.textContent = "* { line-height: 1.5 !important; letter-spacing: 0.12em !important; word-spacing: 0.16em !important; } p { margin-bottom: 2em !important; }";
      document.head.appendChild(style);
    JS
  end

  def open_every_disclosure
    page.execute_script("document.querySelectorAll('details').forEach(d => { d.open = true; })")
  end

  def reviewed_day_for(user)
    GenerateDailyExercisesJob.perform_now(user_id: user.id)
    exercise = DailyExercise.find_by!(user: user, date: Date.current)
    keys = exercise.active_section_keys
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: keys.index_with { "an answer long enough to count" },
                          section_ratings: keys.index_with { "right_level" }, submitted_at: Time.current,
                          ai_review: keys.index_with { { "rating" => "solid", "correct" => "Good catch." } })
  end

  def heights(selector)
    page.evaluate_script("Array.from(document.querySelectorAll(#{selector.to_json})).map(el => el.getBoundingClientRect().height)")
  end

  it "keeps the menu button on screen at 320px, at the default and the largest text size" do
    user = create_fake_provider_user
    resize(320)
    visit_as(user)

    [ {}, { "text_size" => "140", "line_spacing" => "loose", "font" => "atkinson" } ].each do |prefs|
      user.update!(display_preferences: prefs)
      visit learn_path

      expect(page_width).to eq(320)
      expect(page.evaluate_script("document.getElementById('nav-toggle').getBoundingClientRect().right")).to be <= 320
      expect(page.evaluate_script("document.querySelector('.brand-mark').getBoundingClientRect().width")).to be > 0
    end
  end

  it "wraps the submitted day's badge, ratings and review button instead of scrolling sideways" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      GenerateDailyExercisesJob.perform_now(user_id: user.id)
      exercise = DailyExercise.find_by!(user: user, date: Date.current)
      keys = exercise.active_section_keys
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: keys.index_with { "an answer long enough to count" },
                            section_ratings: keys.index_with { "right_level" }, submitted_at: Time.current)
      resize(390)
      visit_as(user)

      expect(page).to have_css(".submit-row")
      expect(page_width).to eq(390)
    end
  end

  it "keeps the review's follow-up field inside the page at 320px with the largest text" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      user.update!(display_preferences: LARGEST)
      reviewed_day_for(user)
      resize(320)
      visit_as(user)

      expect(page).to have_css(".follow-up-input")
      expect(page_width).to eq(320)
    end
  end

  it "keeps the duck's field inside the page at 320px with the largest text" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      user.update!(display_preferences: LARGEST)
      resize(320)
      visit_with_todays_set(user)
      find(".duck-toggle", match: :first).click

      expect(page).to have_css(".duck-input", visible: :visible)
      expect(page_width).to eq(320)
    end
  end

  it "wraps a long email on Account at 320px with the largest text and the spacing override" do
    user = create_fake_provider_user
    user.update!(email: "averyverylongengineeringaddress@example.com", display_preferences: LARGEST)
    resize(320)
    visit_as(user)
    visit account_path
    apply_text_spacing

    expect(page).to have_text(user.email)
    expect(page_width).to eq(320)
  end

  it "wraps Progress rows at 320px with the largest text and the spacing override" do
    user = create_fake_provider_user
    user.update!(display_preferences: LARGEST)
    resize(320)
    visit_as(user)
    visit progress_path
    open_every_disclosure
    apply_text_spacing

    expect(page).to have_css(".progress-entry", visible: :visible)
    expect(page_width).to eq(320)
  end

  it "gives the Learn page's back link a 24px target" do
    resize(390)
    visit_as(create_fake_provider_user)
    visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

    expect(heights(".learn-back")).to all(be >= 24)
  end

  it "gives the answer form's most-tapped controls a 44px target" do
    travel_to(a_weekday) do
      resize(390)
      visit_with_todays_set(create_fake_provider_user)

      expect(heights("details.section > summary")).to all(be >= 44)
      expect(heights(".rating-btn")).to all(be >= 44)
      expect(heights("#submit-answers, #nav-toggle")).to all(be >= 44)
    end
  end

  it "keeps a folded section's label where it was, so the larger target costs no space" do
    travel_to(a_weekday) do
      resize(390)
      visit_with_todays_set(create_fake_provider_user)

      offset = page.evaluate_script(<<~JS)
        (() => {
          const section = document.querySelector("details.section");
          section.open = false;
          return document.querySelector(".section-title").getBoundingClientRect().top - section.getBoundingClientRect().top;
        })()
      JS

      padding_top = page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('details.section')).paddingTop)")
      expect(offset).to be_within(1).of(padding_top)
    end
  end

  it "offers a skip link as the first stop that moves focus to the main content" do
    resize(390)
    visit_as(create_fake_provider_user)
    visit learn_path

    page.driver.with_playwright_page { |pw| pw.keyboard.press("Tab") }
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Skip to content")
    expect(page.evaluate_script("document.activeElement.getBoundingClientRect().top")).to be >= 0

    page.driver.with_playwright_page { |pw| pw.keyboard.press("Enter") }
    expect(page.evaluate_script("document.activeElement.id")).to eq("main-content")
  end
end
