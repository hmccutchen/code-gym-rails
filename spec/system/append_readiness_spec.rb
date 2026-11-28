require "rails_helper"

RSpec.describe "Readiness after appending an exercise", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  it "preserves another tab's saved answer and rating when an untouched tab learns about an append" do
    exercise = create_existing_set(user, keys: %w[code_review])
    response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "The original saved answer." },
      section_ratings: { "code_review" => "right_level" })
    visit_as(user)
    wait_for_js
    wait_for_answers_settled
    expect(find('textarea[data-field="code_review"]').value).to eq("The original saved answer.")

    response.update!(answers: { "code_review" => "The other tab's newer explanation." },
      section_ratings: { "code_review" => "too_easy" })
    exercise.update!(problem_set: exercise.problem_set.merge("pattern" => FakeService::EXERCISE_PROBLEM_SET.fetch("pattern")),
      section_order: %w[code_review pattern])
    page.execute_script('window.dispatchEvent(new Event("focus"))')

    expect(page).to have_css('[data-section-fold="pattern"]')
    wait_for_js_condition(<<~JS.squish)
      window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller~="answer-form"]'), "answer-form").saveTimer === null
    JS
    wait_for_answers_settled

    aggregate_failures do
      expect(response.reload.answers.fetch("code_review")).to eq("The other tab's newer explanation.")
      expect(response.section_ratings.fetch("code_review")).to eq("too_easy")
    end
  end

  [ :blank, :unrated ].each do |added|
    it "#{added == :blank ? 'keeps a valid session ready' : 'blocks submission'} after a #{added} new card without saving old fields" do
      exercise = create_existing_set(user, keys: %w[code_review])
      response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "Move the query outside the loop." },
        section_ratings: { "code_review" => "right_level" })
      visit_as(user)
      wait_for_js
      expect_ready_to_submit
      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.answerPosts = 0;
        window.fetch = (url, options) => {
          if (String(url).endsWith('/responses') && options?.method === 'POST') window.answerPosts++;
          return originalFetch(url, options);
        };
      JS
      exercise.update!(problem_set: exercise.problem_set.merge("design_comparison" => FakeService::EXERCISE_PROBLEM_SET.fetch("design_comparison")),
        section_order: %w[code_review design_comparison])
      response.update!(answers: response.answers.merge("design_comparison" => "pick:a\nA bounded operation.")) if added == :unrated
      page.execute_script('window.dispatchEvent(new Event("focus"))')

      expect(page).to have_css('[data-section-fold="design_comparison"]')
      expect(page).to have_button("Submit answers", disabled: added == :unrated)
      expect(page.evaluate_script("window.answerPosts")).to eq(0)
      expect(response.reload.answers.fetch("code_review")).to eq("Move the query outside the loop.")
    end
  end

  it "does not enable an old blank form because another tab answered an existing section before Add" do
    exercise = create_existing_set(user, keys: %w[code_review])
    visit_as(user)
    wait_for_js
    expect(page).to have_button("Submit answers", disabled: true)
    user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "An answer saved from the other tab." },
      section_ratings: { "code_review" => "right_level" })
    exercise.update!(problem_set: exercise.problem_set.merge("pattern" => FakeService::EXERCISE_PROBLEM_SET.fetch("pattern")),
      section_order: %w[code_review pattern])
    page.execute_script('window.dispatchEvent(new Event("focus"))')

    expect(page).to have_css('[data-section-fold="pattern"]')
    expect(page).to have_button("Submit answers", disabled: true)
    expect(find('textarea[data-field="code_review"]').value).to be_empty
  end
end
