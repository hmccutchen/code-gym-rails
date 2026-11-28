require "rails_helper"

RSpec.describe "Matching an unconfirmed draft after append", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  before { visit_with_existing_set(user, keys: %w[code_review]) }

  def recovered(rendered:, scope: "same", sent: nil)
    page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      import('code_gym/draft_store').then(({ default: DraftCopy }) => {
        const copy = new DraftCopy('before-save', 'same');
        const first = { answers: { code_review: 'Sent answer' }, ratings: { code_review: 'right_level' } };
        copy.store(first);
        copy.recordSend(first);
        copy.store({ answers: { code_review: 'Later unsent edit' }, ratings: first.ratings });
        if (#{!sent.nil?}) {
          const stored = JSON.parse(localStorage.getItem(#{draft_key_js}));
          stored.sent = [#{sent.to_json}];
          localStorage.setItem(#{draft_key_js}, JSON.stringify(stored));
        }
        copy.reconnect('after-save', #{scope.to_json});
        done(copy.restorable(#{rendered.to_json}));
      }).catch((error) => done({ error: String(error) }));
    JS
  end

  let(:rendered) do
    { answers: { code_review: "Sent answer", pattern: "Where this logic lives today:\n" },
      ratings: { code_review: "right_level" }, emptyUnratedSections: %w[pattern] }
  end

  it "permits server-declared empty appended fields even when their display contains a scaffold" do
    expect(recovered(rendered: rendered)).to eq("answers" => { "code_review" => "Later unsent edit" },
      "ratings" => { "code_review" => "right_level" })
  end

  it "rejects conflicts, absent originals, other scopes and malformed saved attempts" do
    cases = [
      { rendered: rendered.merge(emptyUnratedSections: []) },
      { rendered: rendered.merge(ratings: { code_review: "right_level", pattern: "right_level" }) },
      { rendered: rendered.merge(answers: { pattern: "Where this logic lives today:\n" }) },
      { rendered: rendered.merge(answers: { code_review: "Changed elsewhere", pattern: "" }) },
      { rendered: rendered.merge(ratings: {}) },
      { rendered: rendered.merge(ratings: { code_review: "too_hard" }) },
      { rendered: rendered, scope: "different" },
      { rendered: rendered, sent: "not-json" },
      { rendered: rendered, sent: "{}" }
    ]
    cases.each { |options| expect(recovered(**options)).to be_nil }
  end

  %i[empty answered rated].each do |added_state|
  it "recovers behind a lost reply only when the appended scaffold field is empty and unrated: #{added_state}" do
    first = "Saved before the reply went missing."
    later = "Keep this edit made behind the lost reply."
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
    exercise = user.daily_exercises.sole
    exercise.update!(problem_set: exercise.problem_set.merge("pattern" => FakeService::EXERCISE_PROBLEM_SET.fetch("pattern")),
      section_order: %w[code_review pattern])
    response = user.daily_responses.sole
    response.update!(answers: response.answers.merge("pattern" => "Another device answered this.")) if added_state == :answered
    response.update!(section_ratings: { "pattern" => "right_level" }) if added_state == :rated

    visit root_path
    wait_for_js

    expect(find('textarea[data-field="pattern"]').value).not_to be_empty
    expect(find('textarea[data-field="code_review"]').value).to eq(added_state == :empty ? later : first)
    wait_for_draft_cleared
  end
  end
end
