require "rails_helper"

RSpec.describe "Adding an exercise", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  before do
    page.driver.with_playwright_page { |pw| pw.emulate_media(reducedMotion: "reduce") }
    visit_with_existing_set(user, keys: %w[pattern])
  end

  def begin_addition(kind: "code_review", name: "Code Review")
    click_button "+ Add exercise"
    find("dialog input[value='#{kind}']").click
    within("dialog[open]") { click_button "Add exercise" }
    expect(page).to have_text("Preparing #{name}")
  end

  def append_from_another_tab
    exercise = user.daily_exercises.sole
    exercise.update!(problem_set: exercise.problem_set.merge("code_review" => FakeService::EXERCISE_PROBLEM_SET.fetch("code_review")),
      section_order: %w[pattern code_review])
  end

  it "appends the generated card without replacing the focused answer, rating or duck draft" do
    fill_in_answer("pattern", "Keep the calculation separate from its cache.")
    rate_section("pattern")
    begin_addition
    area = find('textarea[data-field="pattern"]')
    area.fill_in(with: "My answer is still being edited.")
    area.click
    page.execute_script('window.originalAnswer = document.querySelector("textarea[data-field=pattern]")')
    page.execute_script('document.querySelector("[data-duck-thread-target=input]").value = "Keep my thinking draft"')

    GenerateAdditionalExerciseJob.perform_now(addition_id: user.daily_exercises.sole.exercise_additions.sole.id)

    expect(page).to have_css('[data-section-fold="code_review"]')
    expect(page.evaluate_script("window.originalAnswer === document.activeElement")).to be(true)
    expect(area.value).to eq("My answer is still being edited.")
    expect(find('button[data-rating-for="pattern"][data-rating="right_level"]')["aria-pressed"]).to eq("true")
    expect(page.evaluate_script('document.querySelector("[data-duck-thread-target=input]").value')).to eq("Keep my thinking draft")
    fill_in_answer("code_review", "The query belongs outside the loop.")
    wait_for { user.daily_responses.first&.answers&.fetch("code_review", nil) == "The query belongs outside the loop." }
    expect(page).to have_css('[data-section-fold="code_review"]', count: 1)
  end

  it "merges an appended saved answer without replacing existing live answer state" do
    fill_in_answer("pattern", "Keep my existing explanation.")
    rate_section("pattern")
    wait_for_answers_settled
    expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
    append_from_another_tab
    user.daily_responses.sole.update!(answers: { "code_review" => "Move the query outside the loop." },
      section_ratings: { "code_review" => "right_level" })

    page.execute_script('window.dispatchEvent(new Event("focus"))')

    expect(page).to have_css('[data-section-fold="code_review"]')
    expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
    expect(page).to have_css('[data-hint-for="code_review"] > details.hint')
    expect(find('textarea[data-field="code_review"]').value).to eq("Move the query outside the loop.")
    expect(find('textarea[data-field="pattern"]').value).to eq("Keep my existing explanation.")
    expect(find('button[data-rating-for="pattern"][data-rating="right_level"]')["aria-pressed"]).to eq("true")
    expect(find('button[data-rating-for="code_review"][data-rating="right_level"]')["aria-pressed"]).to eq("true")
    expect(user.daily_responses.sole.answers).to eq("code_review" => "Move the query outside the loop.")
  end

  it "clears stale answered state for an unseen section when its inserted card is now blank" do
    fill_in_answer("pattern", "Keep my existing explanation.")
    rate_section("pattern")
    wait_for_answers_settled
    expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
    append_from_another_tab
    page.execute_script(<<~JS)
      const form = document.querySelector('[data-controller~="answer-form"]');
      window.Stimulus.getControllerForElementAndIdentifier(form, "answer-form")
        .applyServerState({ answered_sections: ["pattern", "code_review"] });
    JS
    user.daily_responses.sole.update!(answers: {}, section_ratings: {})

    page.execute_script('window.dispatchEvent(new Event("focus"))')

    expect(page).to have_css('[data-section-fold="code_review"]')
    expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
    expect(page).to have_css('[data-hint-for="code_review"] > .hint-locked')
    expect(page).to have_no_css('[data-hint-for="code_review"] > details.hint')
    expect(find('textarea[data-field="code_review"]').value).to eq("")
    expect(find('textarea[data-field="pattern"]').value).to eq("Keep my existing explanation.")
    expect(find('button[data-rating-for="pattern"][data-rating="right_level"]')["aria-pressed"]).to eq("true")
    expect(user.daily_responses.sole.answers).to eq({})
  end

  it "refreshes an unseen manifest before submitting without discarding the current answer" do
    fill_in_answer("pattern", "Reuse the cached result.")
    rate_section("pattern")
    wait_for { user.daily_responses.first&.answers&.fetch("pattern", nil) == "Reuse the cached result." }
    wait_for_answers_settled
    append_from_another_tab

    click_button "Submit"

    expect(page).to have_css('[data-section-fold="code_review"]')
    expect(find('textarea[data-field="pattern"]').value).to eq("Reuse the cached result.")
    expect(user.daily_responses.sole).not_to be_submitted
  end

  it "uses the mobile sheet with keyboard dismissal and returns focus to Add" do
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 600) }
    click_button "+ Add exercise"
    expect(page).to have_css("dialog[open] input[type=radio]")
    expect(page).to have_no_css('dialog[open] label[data-kind="pattern"]', visible: :visible)
    page.driver.with_playwright_page { |pw| pw.keyboard.press("Escape") }

    expect(page).to have_no_css("dialog[open]")
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("+ Add exercise")
  end

  it "restores an offline answer after another tab appends and the page reloads" do
    drop_requests_to("/responses")
    fill_in_answer("pattern", "Keep this offline explanation.")
    wait_for_js_condition("#{stored_draft_js}?.answers?.pattern === 'Keep this offline explanation.'")
    append_from_another_tab

    visit root_path
    wait_for_js

    expect(page).to have_css('[data-section-fold="code_review"]')
    expect(find('textarea[data-field="pattern"]').value).to eq("Keep this offline explanation.")
    wait_for_draft_cleared
    expect(user.daily_responses.sole.answers.fetch("pattern")).to eq("Keep this offline explanation.")
  end

  it "offers an explicit retry for an expired request and uses a fresh request identity" do
    begin_addition
    first = user.daily_exercises.sole.exercise_additions.sole
    first.update_columns(created_at: 2.days.ago)
    page.execute_script('window.dispatchEvent(new Event("focus"))')
    expect(page).to have_text("The exercise wasn't added")

    begin_addition

    requests = user.daily_exercises.sole.exercise_additions.order(:id)
    expect(requests.size).to eq(2)
    expect(requests.first.status).to eq("failed")
    expect(requests.last.request_uuid).not_to eq(first.request_uuid)
  end

  it "reuses the request identity when acceptance succeeded but its reply was lost" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.additionRequests = [];
      window.fetch = async (url, options) => {
        if (!String(url).startsWith('/exercise_additions')) return originalFetch(url, options);
        if (options?.method !== 'POST' && window.additionRequests.length < 2) throw new TypeError('Offline');
        if (options?.method === 'POST') window.additionRequests.push(JSON.parse(options.body).request_uuid);
        const result = await originalFetch(url, options);
        if (options?.method === 'POST' && window.additionRequests.length === 1) throw new TypeError('Reply lost');
        return result;
      };
    JS
    click_button "+ Add exercise"
    find('dialog input[value="code_review"]').click
    within("dialog[open]") { click_button "Add exercise" }
    expect(page).to have_css('[data-exercise-addition-target="error"]', text: /\S/)

    within("dialog[open]") { click_button "Add exercise" }

    expect(page).to have_text("Preparing Code Review")
    requests = page.evaluate_script("window.additionRequests")
    expect(requests.size).to eq(2)
    expect(requests.uniq.size).to eq(1)
    expect(user.daily_exercises.sole.exercise_additions.count).to eq(1)
  end

  it "connects an appended structured answer and submits it without requiring the original exercise" do
    begin_addition(kind: "design_comparison", name: "Design Comparison")
    GenerateAdditionalExerciseJob.perform_now(addition_id: user.daily_exercises.sole.exercise_additions.sole.id)
    expect(page).to have_css('[data-comparison-answer="design_comparison"]')
    fill_in_answer("design_comparison", "The second design keeps retries in one place.")
    rate_section("design_comparison")

    click_button "Submit"

    wait_for { user.daily_responses.first&.submitted? }
    stored = user.daily_responses.sole
    expect(stored.answered_sections).to eq(%w[design_comparison])
    expect(stored.answers.fetch("design_comparison")).to include("pick:a", "The second design keeps retries in one place.")
    expect(stored.section_ratings).to eq("design_comparison" => "right_level")
  end
end
