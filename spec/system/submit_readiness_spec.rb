require "rails_helper"

RSpec.describe "Confirmed submission readiness", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday) { example.run } }

  before do
    visit_with_existing_set(user, keys: %w[code_review pattern])
  end

  it "requires the latest saved answer and rating, including explicit rating clears" do
    expect(page).to have_button("Submit answers", disabled: true)
    fill_in_answer("code_review", "Move the query outside the loop.")
    rate_section("code_review")
    expect(page).to have_button("Submit answers", disabled: false)

    page.execute_script(<<~JS)
      const area = document.querySelector('textarea[data-field="code_review"]');
      area.value = '';
      area.dispatchEvent(new Event('input', { bubbles: true }));
      window.disabledAtEdit = document.querySelector('[data-answer-form-target="submitButton"]').disabled;
    JS
    expect(page.evaluate_script("window.disabledAtEdit")).to be(true)
    wait_for_answers_settled
    expect(page).to have_button("Submit answers", disabled: true)

    fill_in_answer("code_review", "Move the query outside the loop.")
    expect(page).to have_button("Submit answers", disabled: false)
    rate_section("code_review")
    wait_for_answers_settled
    expect(page).to have_button("Submit answers", disabled: true)
    expect(page).to have_css('[data-rating-for="code_review"][aria-pressed="true"]', count: 0)
    expect(user.daily_responses.sole.section_ratings).not_to have_key("code_review")
    rate_section("code_review")
    expect(page).to have_button("Submit answers", disabled: false)
    fill_in_answer("pattern", "Extract the operation into its own object.")
    wait_for_answers_settled
    expect(page).to have_button("Submit answers", disabled: true)
    rate_section("pattern")
    expect(page).to have_button("Submit answers", disabled: false)
  end

  it "stays disabled while an older valid acknowledgement arrives before a newer edit" do
    fill_in_answer("code_review", "Move the query outside the loop.")
    rate_section("code_review")
    wait_for_answers_settled
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      let held = false;
      window.fetch = async (url, options) => {
        if (!String(url).endsWith('/responses') || held) return originalFetch(url, options);
        held = true;
        const response = await originalFetch(url, options);
        return new Promise(resolve => { window.releaseOldSave = () => resolve(response); });
      };
    JS
    fill_in_answer("code_review", "An updated valid answer.")
    wait_for_js_condition("typeof window.releaseOldSave === 'function'")
    fill_in_answer("pattern", "Another answer with no rating.")
    page.execute_script("window.releaseOldSave()")
    expect(page).to have_button("Submit answers", disabled: true)
    wait_for_answers_settled
    expect(page).to have_button("Submit answers", disabled: true)
  end
end
