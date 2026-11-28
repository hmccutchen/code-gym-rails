require "rails_helper"

RSpec.describe "Draft recovery after adding an exercise", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  it "keeps edits behind a lost save reply when another tab appends an unanswered comparison" do
    visit_with_existing_set(user, keys: %w[code_review])
    first = "The repeated query belongs outside the loop."
    later = "#{first} Keep this later unsent explanation too."
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = async (url, options) => {
        if (new URL(url, location.href).pathname !== '/responses') return originalFetch(url, options);
        if (window.firstSaveSent) throw new TypeError('Offline');
        window.firstSaveSent = true;
        await originalFetch(url, options);
        throw new TypeError('Reply lost');
      };
    JS
    fill_in_answer("code_review", first)
    wait_for { user.daily_responses.first&.answers&.fetch("code_review", nil) == first }
    fill_in_answer("code_review", later)
    wait_for_js_condition("#{stored_draft_js}?.answers?.code_review === #{later.to_json}")
    wait_for_js_condition("(#{stored_draft_js}?.sent || []).some((sent) => sent.includes(#{first.to_json}))")
    exercise = user.daily_exercises.sole
    exercise.update!(problem_set: exercise.problem_set.merge("design_comparison" => FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison")),
      section_order: %w[code_review design_comparison])

    visit root_path
    wait_for_js

    expect(page).to have_css('[data-comparison-answer="design_comparison"]')
    expect(find('textarea[data-field="code_review"]').value).to eq(later)
    wait_for_draft_cleared
    expect(user.daily_responses.sole.answers.fetch("code_review")).to eq(later)
  end
end
