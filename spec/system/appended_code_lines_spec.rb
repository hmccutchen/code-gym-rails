require "rails_helper"

RSpec.describe "Wrapping code in an appended exercise", type: :system do
  let(:user) { create_fake_provider_user }
  let(:source) { "def total\n  kind     = \"a string that is too long for a phone screen\"\n  kind\nend" }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  it "fits appended padding while preserving old code and inputs across repeated notifications" do
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 320, height: 844) }
    exercise = create_existing_set(user, keys: %w[code_review])
    exercise.update!(problem_set: exercise.problem_set.deep_merge("code_review" => { "snippet" => source }))
    visit_as(user)
    wait_for_js
    expect(page).to have_css('[data-section-fold="code_review"] code.highlight[data-wraps]')
    fill_in_answer("code_review", "Keep this answer while another exercise arrives.")
    page.execute_script(<<~JS)
      window.keptCode = document.querySelector('[data-section-fold="code_review"] code.highlight');
      window.keptAnswer = document.querySelector('textarea[data-field="code_review"]');
    JS
    added = FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison").merge("piece_a" => source)
    exercise.update!(problem_set: exercise.problem_set.merge("design_comparison" => added),
      section_order: %w[code_review design_comparison])

    page.execute_script('window.dispatchEvent(new Event("focus"))')

    expect(page).to have_css('[data-section-fold="design_comparison"] code.highlight[data-wraps]')
    2.times { page.execute_script('document.body.dispatchEvent(new CustomEvent("code-gym:sections-added"))') }
    expect(page.evaluate_script(<<~JS)).to eq("0px")
      getComputedStyle(document.querySelector('[data-section-fold="design_comparison"] .code-align-extra')).fontSize
    JS
    expect(page.evaluate_script('window.keptCode === document.querySelector("[data-section-fold=code_review] code.highlight")')).to be(true)
    expect(page.evaluate_script('window.keptAnswer === document.querySelector("textarea[data-field=code_review]")')).to be(true)
    expect(find('textarea[data-field="code_review"]').value).to eq("Keep this answer while another exercise arrives.")
  end
end
