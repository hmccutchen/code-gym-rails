require "rails_helper"

RSpec.describe "Recovering cleared draft ratings", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday) { example.run } }

  before do
    visit_with_existing_set(user, keys: %w[code_review])
    fill_in_answer("code_review", "Move the repeated query outside the loop.")
    rate_section("code_review")
    wait_for_answers_settled
  end

  it "restores an offline clear and keeps submission unavailable until a new rating is saved" do
    break_the_network
    rate_section("code_review")
    wait_for_js_condition("#{stored_draft_js}?.ratings?.code_review === null")
    expect(page).to have_button("Submit answers", disabled: true)

    visit root_path
    wait_for_js
    wait_for_answers_settled

    expect(page).to have_no_css('[data-rating-for="code_review"][aria-pressed="true"]')
    expect(user.daily_responses.sole.section_ratings).to eq({})
    expect(page).to have_button("Submit answers", disabled: true)
    rate_section("code_review")
    expect(page).to have_button("Submit answers", disabled: false)
  end

  [ false, true ].each do |changed_elsewhere|
    it "#{changed_elsewhere ? 'rejects' : 'restores'} edits behind a lost clear acknowledgement #{changed_elsewhere ? 'after a competing rating' : 'with unchanged saved state'}" do
      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.fetch = async (url, options) => {
          if (new URL(url, location.href).pathname !== '/responses') return originalFetch(url, options);
          if (window.firstClearSent) throw new TypeError('Offline');
          window.firstClearSent = true;
          await originalFetch(url, options);
          throw new TypeError('Reply lost');
        };
      JS
      rate_section("code_review")
      wait_for { user.daily_responses.sole.section_ratings.empty? }
      later = "Keep this newer explanation after clearing the rating."
      fill_in_answer("code_review", later)
      wait_for_js_condition("#{stored_draft_js}?.answers?.code_review === #{later.to_json}")
      user.daily_responses.sole.update!(section_ratings: { "code_review" => "too_hard" }) if changed_elsewhere

      visit root_path
      wait_for_js
      wait_for_answers_settled

      expect(find('textarea[data-field="code_review"]').value).to eq(changed_elsewhere ? "Move the repeated query outside the loop." : later)
      expect(user.daily_responses.sole.section_ratings).to eq(changed_elsewhere ? { "code_review" => "too_hard" } : {})
    end
  end
end
