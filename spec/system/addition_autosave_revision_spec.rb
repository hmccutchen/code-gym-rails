require "rails_helper"

RSpec.describe "Autosave replies across an appended exercise", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  before do
    visit_with_existing_set(user, keys: %w[pattern])
    fill_in_answer("pattern", "Keep the calculation separate.")
    rate_section("pattern")
    wait_for_answers_settled
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.answerSaves = [];
      window.fetch = async (url, options) => {
        if (!String(url).endsWith('/responses') || options?.method !== 'POST') return originalFetch(url, options);
        window.answerSaves.push(JSON.parse(options.body));
        const result = await originalFetch(url, options);
        if (window.answerSaves.length !== 1) return result;
        window.heldAnswerReply = await result.clone().json();
        return new Promise(resolve => { window.releaseAnswerReply = () => resolve(result); });
      };
    JS
    fill_in_answer("pattern", "Keep the calculation separate from its cache.")
    wait_for_js_condition("typeof window.releaseAnswerReply === 'function'")
    expect(page.evaluate_script("window.heldAnswerReply.manifest_revision")).to eq(1)
    exercise = user.daily_exercises.sole
    exercise.update!(problem_set: exercise.problem_set.merge("code_review" => FakeService::EXERCISE_PROBLEM_SET.fetch("code_review")),
      section_order: %w[pattern code_review])
    response = user.daily_responses.sole
    response.update!(answers: response.answers.merge("code_review" => "Move the query outside the loop."),
      section_ratings: response.section_ratings.merge("code_review" => "right_level"))
    page.execute_script('window.dispatchEvent(new Event("focus"))')
    expect(page).to have_css('[data-section-fold="code_review"]')
    expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
    expect(page).to have_css('[data-hint-for="code_review"] > details.hint')
  end

  it "keeps the newer card answered and refreshes the expanded form after an older reply" do
    page.execute_script("window.releaseAnswerReply()")
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

    expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
    expect(page).to have_css('[data-hint-for="code_review"] > details.hint')
    expect(find('textarea[data-field="code_review"]').value).to eq("Move the query outside the loop.")
    wait_for_answers_settled
    saves = page.evaluate_script("window.answerSaves")
    expect(saves.size).to eq(2)
    expect(saves.last.fetch("response")).to include("manifest_revision" => 2,
      "answers" => { "pattern" => "Keep the calculation separate from its cache.", "code_review" => "Move the query outside the loop." },
      "section_ratings" => { "pattern" => "right_level", "code_review" => "right_level" })
  end

  %w[scheduled queued].each do |pending|
    it "keeps a #{pending} newer edit without sending an extra refresh" do
      page.execute_script(<<~JS)
        const element = document.querySelector('[data-controller~="answer-form"]');
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "answer-form");
        const area = document.querySelector('textarea[data-field="pattern"]');
        area.value = "Keep this newer explanation.";
        area.dispatchEvent(new Event("input", { bubbles: true }));
        if (#{pending == "queued"}) controller.sendSave();
        window.releaseAnswerReply();
      JS
      wait_for_answers_settled

      expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
      expect(page).to have_css('[data-hint-for="code_review"] > details.hint')
      expect(page.evaluate_script("window.answerSaves.length")).to eq(2)
      expect(user.daily_responses.sole.answers).to include("pattern" => "Keep this newer explanation.",
        "code_review" => "Move the query outside the loop.")
    end
  end

  it "does not refresh or replace answer state while the form is inert" do
    page.execute_script(<<~JS)
      document.querySelector('[data-answer-form-target="form"]').inert = true;
      window.releaseAnswerReply();
    JS
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

    expect(page).to have_css('[data-hint-for="pattern"] > details.hint')
    expect(page).to have_css('[data-hint-for="code_review"] > details.hint')
    expect(page.evaluate_script("window.answerSaves.length")).to eq(1)
  end
end
