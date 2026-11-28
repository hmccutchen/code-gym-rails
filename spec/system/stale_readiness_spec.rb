require "rails_helper"

RSpec.describe "Draft protection after submission readiness becomes stale", type: :system, with_csrf: true do
  let(:user) { create_fake_provider_user }
  let(:later_answer_saves) { [] }

  around { |example| travel_to(a_weekday) { example.run } }

  before do
    stub_env("STALE_SET_BANNER" => "1", "HELD_SET_LOOKUP" => nil)
    visit_with_todays_set(user)
    fill_in_answer("code_review", "Move the query outside the loop.")
    rate_section("code_review")
    expect_ready_to_submit
    wait_for_answers_settled
    page.driver.with_playwright_page do |pw|
      pw.on("request", ->(request) { later_answer_saves << request.url if URI(request.url).path == responses_path })
    end

    exercise = user.daily_exercises.sole
    exercise.update!(date: exercise.date - 1)
    exercise.daily_response.update!(date: exercise.date)
    user.update!(paused_generation_at: exercise.date.beginning_of_day + 9.hours)
  end

  def check_freshness
    gap_ms = Integer(find("[data-controller~='fresh-day']", visible: :all)["data-fresh-day-minimum-gap-value"])
    page.driver.with_playwright_page do |pw|
      pw.clock.install
      pw.clock.fast_forward(gap_ms + 1000)
      pw.mouse.move(200, 200)
      pw.mouse.move(240, 260)
    end
  end

  def expect_clean_banner
    expect(page).to have_css("#stale-set-banner", text: I18n.t("dashboard.stale_set.carried_forward"))
    expect(page).to have_button(I18n.t("dashboard.stale_set.reload"), exact: true)
    expect(page).to have_button("Submit answers", disabled: true)
  end

  def expect_protected_edit
    page.driver.with_playwright_page { |pw| pw.clock.fast_forward(2000) }
    aggregate_failures do
      expect(page).to have_button("Submit answers", disabled: true)
      expect(page.evaluate_script("window.CodeGymSaveStatus.unsaved()")).to be(true)
      expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(false)
      expect(later_answer_saves).to be_empty
      expect(page).to have_css("#stale-set-banner", text: I18n.t("dashboard.stale_set.unsaved"))
      expect(page).to have_button(I18n.t("dashboard.stale_set.reload_and_discard"))
      yield
    end
  end

  it "keeps an answer typed after a clean freshness banner in the local draft and warns before discarding" do
    check_freshness
    expect_clean_banner
    fill_in_answer("code_review", "A new answer typed behind the banner.")

    expect_protected_edit do
      expect(page.evaluate_script("#{stored_draft_js}?.answers?.code_review")).to eq("A new answer typed behind the banner.")
    end
  end

  it "keeps a rating cleared after a clean freshness banner in the local draft and warns before discarding" do
    check_freshness
    expect_clean_banner
    rate_section("code_review")

    expect_protected_edit do
      expect(page).to have_css('[data-rating-for="code_review"][aria-pressed="true"]', count: 0)
      expect(page.evaluate_script("#{stored_draft_js}?.ratings")).to eq("code_review" => nil)
    end
  end

  it "keeps a pending answer marked unsaved when the freshness banner cancels its debounce timer" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = async (url, options) => {
        const response = await originalFetch(url, options);
        if (!String(url).includes('/dashboard/freshness')) return response;
        return new Promise(resolve => { window.releaseFreshness = () => resolve(response); });
      };
    JS
    check_freshness
    wait_for_js_condition("typeof window.releaseFreshness === 'function'")
    page.execute_script(<<~JS)
      const area = document.querySelector('textarea[data-field="code_review"]');
      area.value = 'An answer waiting for its debounce timer.';
      area.dispatchEvent(new Event('input', { bubbles: true }));
      window.releaseFreshness();
    JS
    expect(page).to have_css("#stale-set-banner", text: I18n.t("dashboard.stale_set.carried_forward"))

    expect_protected_edit do
      expect(page.evaluate_script("#{stored_draft_js}?.answers?.code_review")).to eq("An answer waiting for its debounce timer.")
    end
  end

  it "drops a queued answer transmission when a freshness banner appears before the first reply" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = async (url, options) => {
        const response = await originalFetch(url, options);
        if (!String(url).endsWith('/responses')) return response;
        return new Promise(resolve => { window.releaseAnswer = () => resolve(response); });
      };
    JS
    fill_in_answer("code_review", "The first pending answer.")
    rate_section("code_review", value: "too_easy")
    wait_for_js_condition("typeof window.releaseAnswer === 'function'")
    fill_in_answer("code_review", "The newer queued answer.")
    rate_section("code_review", value: "right_level")
    wait_for_js_condition("window.CodeGymSaveStatus.queued('answers')")

    check_freshness
    expect(page).to have_css("#stale-set-banner", text: I18n.t("dashboard.stale_set.carried_forward"))
    later_answer_saves.clear
    page.execute_script("window.releaseAnswer()")
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

    expect_protected_edit do
      expect(page.evaluate_script("#{stored_draft_js}?.answers?.code_review")).to eq("The newer queued answer.")
    end
  end

  it "drops an offline retry after the freshness banner while retaining the unsent answer" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.answerAttempts = 0;
      window.fetch = async (url, options) => {
        if (String(url).endsWith('/responses')) {
          window.answerAttempts += 1;
          throw new TypeError('Failed to fetch');
        }
        const response = await originalFetch(url, options);
        if (!String(url).includes('/dashboard/freshness')) return response;
        return new Promise(resolve => { window.releaseFreshness = () => resolve(response); });
      };
    JS
    check_freshness
    wait_for_js_condition("typeof window.releaseFreshness === 'function'")
    fill_in_answer("code_review", "An answer awaiting an offline retry.")
    rate_section("code_review", value: "too_easy")
    expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.saving_offline"))
    page.execute_script("window.releaseFreshness()")
    expect(page).to have_css("#stale-set-banner", text: I18n.t("dashboard.stale_set.carried_forward"))
    page.execute_script("window.dispatchEvent(new Event('online'))")
    wait_for_js_condition("!window.CodeGymSaveStatus.pending()")

    expect_protected_edit do
      expect(page.evaluate_script("window.answerAttempts")).to eq(1)
      expect(page.evaluate_script("#{stored_draft_js}?.answers?.code_review")).to eq("An answer awaiting an offline retry.")
    end
  end
end
