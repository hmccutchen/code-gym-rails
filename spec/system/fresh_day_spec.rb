require "rails_helper"

RSpec.describe "A dashboard left open while a newer set arrives", type: :system do
  let(:user) { create_fake_provider_user }

  let(:freshness_checks) { [] }

  def open_dashboard
    visit_with_todays_set(user)
    expect(page).to have_content(/Code Review/i)
    watch_this_load
  end

  def watch_this_load
    page.execute_script("window.__sameLoad = true")
    page.driver.with_playwright_page do |pw|
      pw.clock.install
      pw.on("request", ->(request) { freshness_checks << request.url if URI(request.url).path == dashboard_freshness_path })
    end
  end

  def let_the_minimum_gap_pass
    gap_ms = Integer(find("[data-controller~='fresh-day']", visible: :all)["data-fresh-day-minimum-gap-value"])
    page.driver.with_playwright_page { |pw| pw.clock.fast_forward(gap_ms + 1000) }
  end

  def move_the_pointer
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(200, 200)
      pw.mouse.move(240, 260)
    end
  end

  def dispatch(event, on: "window")
    page.execute_script("#{on}.dispatchEvent(new Event(#{event.to_json}))")
  end

  def report_visibility_as(state)
    page.execute_script("Object.defineProperty(document, 'visibilityState', { get: () => #{state.to_json}, configurable: true })")
  end

  def press_a_key
    page.driver.with_playwright_page { |pw| pw.keyboard.press("Shift") }
  end

  def hold_save_replies
    page.execute_script(<<~JS)
      const original = window.fetch;
      window.__releaseSaves = () => {};
      window.fetch = (url, options) => {
        const sent = original(url, options);
        if (options?.method !== "POST") return sent;
        return new Promise((resolve) => { window.__releaseSaves = () => resolve(sent); });
      };
    JS
  end

  def release_save_replies = page.execute_script("window.__releaseSaves()")

  def same_load? = page.evaluate_script("window.__sameLoad === true")

  def replaced_notice = I18n.t("dashboard.fresh_day.replaced")

  def write_a_set_for_today_like(shown)
    DailyExercise.create!(user: user, date: Date.current, generated_at: 1.minute.from_now, language: shown.language,
                          problem_set: shown.problem_set, plan_notes: shown.plan_notes)
  end

  def replace_todays_set
    user.daily_exercises.sole.tap { |exercise| exercise.update!(generated_at: 1.minute.from_now) }.draft_scope
  end

  it "reloads to the newer set once someone is back at the page" do
    travel_to(a_weekday) do
      open_dashboard
      newer_scope = replace_todays_set

      let_the_minimum_gap_pass
      move_the_pointer

      expect(page).to have_css(%([data-answer-form-draft-scope-value="#{newer_scope}"]))
      expect(same_load?).to be(false)
    end
  end

  it "stays on the page when the set has not changed" do
    travel_to(a_weekday) do
      open_dashboard

      let_the_minimum_gap_pass
      move_the_pointer

      wait_for { freshness_checks.size == 1 }
      move_the_pointer
      expect(same_load?).to be(true)
      expect(freshness_checks.size).to eq(1)
    end
  end

  it "sends nothing while nobody is there, however long the page stays open" do
    travel_to(a_weekday) do
      open_dashboard
      replace_todays_set

      let_the_minimum_gap_pass
      let_the_minimum_gap_pass

      expect(same_load?).to be(true)
      expect(freshness_checks).to be_empty
    end
  end

  { "the window gaining focus" => -> { dispatch("focus") },
    "the page being shown again" => -> { dispatch("pageshow") },
    "the tab becoming visible" => -> { dispatch("visibilitychange", on: "document") },
    "a key press" => -> { press_a_key } }.each do |signal, give|
    it "checks on #{signal}" do
      travel_to(a_weekday) do
        open_dashboard

        let_the_minimum_gap_pass
        instance_exec(&give)

        wait_for { freshness_checks.size == 1 }
        expect(same_load?).to be(true)
      end
    end
  end

  it "sends nothing for a signal that reaches a hidden tab, and checks once the tab is visible" do
    travel_to(a_weekday) do
      open_dashboard
      let_the_minimum_gap_pass

      report_visibility_as("hidden")
      dispatch("visibilitychange", on: "document")
      dispatch("focus")
      dispatch("pageshow")
      press_a_key
      move_the_pointer

      expect(same_load?).to be(true)
      expect(freshness_checks).to be_empty

      report_visibility_as("visible")
      dispatch("visibilitychange", on: "document")

      wait_for { freshness_checks.size == 1 }
    end
  end

  it "holds the reload while an answer save is out, and leaves once it lands" do
    travel_to(a_weekday) do
      open_dashboard
      hold_save_replies
      find(%(textarea[data-field="code_review"])).fill_in(with: "An answer typed just before the set changed")
      wait_for { user.daily_responses.first&.answers&.dig("code_review") == "An answer typed just before the set changed" }
      newer_scope = replace_todays_set

      let_the_minimum_gap_pass
      move_the_pointer

      wait_for { freshness_checks.size == 1 }
      expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(true)
      expect(page).to have_no_css(%([data-answer-form-draft-scope-value="#{newer_scope}"]), wait: 1)
      expect(same_load?).to be(true)

      release_save_replies

      expect(page).to have_css(%([data-answer-form-draft-scope-value="#{newer_scope}"]))
      expect(same_load?).to be(false)
      expect(find(%(textarea[data-field="code_review"])).value).to eq("An answer typed just before the set changed")
    end
  end

  it "says the set was replaced when the set the page showed was written again the same day" do
    travel_to(a_weekday) do
      open_dashboard
      newer_scope = replace_todays_set

      let_the_minimum_gap_pass
      move_the_pointer

      expect(page).to have_css(%([data-answer-form-draft-scope-value="#{newer_scope}"]))
      expect(page).to have_css("#save-status", text: replaced_notice)
    end
  end

  it "says nothing when the page showed an older day's set" do
    travel_to(a_weekday) do
      open_dashboard
      shown = user.daily_exercises.sole
      shown.update!(date: Date.current - 1)
      todays = write_a_set_for_today_like(shown)

      let_the_minimum_gap_pass
      move_the_pointer

      expect(page).to have_css(%([data-answer-form-draft-scope-value="#{todays.draft_scope}"]))
      expect(same_load?).to be(false)
      expect(page).to have_no_css("#save-status", visible: true)
    end
  end

  it "says nothing when the page showed no set" do
    travel_to(a_weekday) do
      user.update!(paused_generation_at: Time.current)
      visit_as(user)
      wait_for_js
      expect(page).to have_css("[data-controller~='fresh-day'][data-fresh-day-shown-value='']", visible: :all)
      watch_this_load
      perform_enqueued_jobs { GenerateDailyExercisesJob.perform_now(user_id: user.id) }
      todays = user.daily_exercises.sole

      let_the_minimum_gap_pass
      move_the_pointer

      expect(page).to have_css(%([data-answer-form-draft-scope-value="#{todays.draft_scope}"]))
      expect(same_load?).to be(false)
      expect(page).to have_no_css("#save-status", visible: true)
    end
  end

  it "does not check a page that has only just loaded" do
    travel_to(a_weekday) do
      open_dashboard
      replace_todays_set

      move_the_pointer

      expect(same_load?).to be(true)
      expect(freshness_checks).to be_empty
    end
  end
end
