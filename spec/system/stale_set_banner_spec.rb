require "rails_helper"

RSpec.describe "The out-of-date banner on a dashboard left open", type: :system, with_csrf: true do
  let(:user) { create_fake_provider_user }

  before { stub_env("STALE_SET_BANNER" => "1") }

  def open_dashboard(ready: false)
    visit_with_todays_set(user)
    expect(page).to have_content(/Code Review/i)
    if ready
      fill_in_answer("code_review", "Move the query outside the loop.")
      rate_section("code_review")
      expect_ready_to_submit
      wait_for_answers_settled
    end
    watch_this_load
  end

  def watch_this_load
    page.execute_script("window.__sameLoad = true")
    page.driver.with_playwright_page { |pw| pw.clock.install }
  end

  def same_load? = page.evaluate_script("window.__sameLoad === true")

  def let_the_minimum_gap_pass
    gap_ms = Integer(find("[data-controller~='fresh-day']", visible: :all)["data-fresh-day-minimum-gap-value"])
    page.driver.with_playwright_page { |pw| pw.clock.fast_forward(gap_ms + 1000) }
  end

  def check_freshness
    let_the_minimum_gap_pass
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(200, 200)
      pw.mouse.move(240, 260)
    end
  end

  def pass_midnight
    exercise = user.daily_exercises.sole
    exercise.update!(date: exercise.date - 1)
    exercise.daily_response&.update!(date: exercise.date)
    exercise
  end

  def replace_todays_set
    user.daily_exercises.sole.tap { |exercise| exercise.update!(generated_at: 1.minute.from_now) }.draft_scope
  end

  def open_duck
    duck = first(".duck-thread[data-duck-thread-section-value='code_review']")
    duck.find(".duck-toggle").click
    duck
  end

  def submitted_set
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "Service Objects", "question" => "When?", "concept" => "service_objects" }
      }
    )
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "an answer", "pattern" => "another" },
                          section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
                          submitted_at: Time.current,
                          ai_review: %w[code_review pattern].index_with { { "rating" => "solid", "correct" => "Right" } })
  end

  def banner = find("#stale-set-banner")

  def unsaved_line = I18n.t("dashboard.stale_set.unsaved")

  def discard_label = I18n.t("dashboard.stale_set.reload_and_discard")

  def expect_banner(sentence_key, unsaved:)
    expect(page).to have_css("#stale-set-banner[role='status']", text: I18n.t("dashboard.stale_set.#{sentence_key}"))
    if unsaved
      expect(banner).to have_text(unsaved_line)
      expect(banner).to have_button(discard_label)
    else
      expect(banner).to have_no_text(unsaved_line)
      expect(banner).to have_button(I18n.t("dashboard.stale_set.reload"), exact: true)
    end
  end

  def expect_generating_screen
    expect(page).to have_css(".today-state-title", text: I18n.t("dashboard.generating.title"))
    expect(same_load?).to be(false)
  end

  describe "past midnight, unpaused, with no set for today" do
    it "shows the banner on a freshness check, never reloads by itself, and Reload starts today's set" do
      travel_to(a_weekday) do
        open_dashboard
        pass_midnight

        check_freshness

        expect_banner(:starts_generation, unsaved: false)
        expect(same_load?).to be(true)

        duck = open_duck
        duck.find(".duck-input").fill_in(with: "A question typed after the banner showed")
        expect_banner(:starts_generation, unsaved: true)
        duck.find(".duck-input").fill_in(with: "")
        expect_banner(:starts_generation, unsaved: false)

        banner.click_button(I18n.t("dashboard.stale_set.reload"))
        expect_generating_screen
      end
    end

    it "shows the banner when an autosave is refused, keeps the answer, and Reload discards it" do
      travel_to(a_weekday) do
        open_dashboard
        pass_midnight

        find(%(textarea[data-field="code_review"])).fill_in(with: "An answer typed after midnight")

        expect_banner(:starts_generation, unsaved: true)
        expect(same_load?).to be(true)
        expect(find(%(textarea[data-field="code_review"])).value).to eq("An answer typed after midnight")

        banner.click_button(discard_label)
        expect_generating_screen
        expect(DailyResponse.count).to eq(0)
      end
    end

    it "shows the banner when a duck send is refused, and the text stays in the box until Reload" do
      travel_to(a_weekday) do
        open_dashboard
        pass_midnight
        duck = open_duck

        duck.find(".duck-input").fill_in(with: "Why is this slow?")
        duck.find(".duck-send").click

        expect_banner(:starts_generation, unsaved: true)
        expect(duck.find(".duck-input").value).to eq("Why is this slow?")
        expect(same_load?).to be(true)

        banner.click_button(discard_label)
        expect_generating_screen
      end
    end

    it "shows the banner when a submit is refused" do
      travel_to(a_weekday) do
        open_dashboard(ready: true)
        pass_midnight

        find("#submit-answers").click

        expect_banner(:starts_generation, unsaved: true)
        expect(same_load?).to be(true)
      end
    end

    it "keeps unsent duck text when a freshness check shows the banner" do
      travel_to(a_weekday) do
        open_dashboard
        pass_midnight
        duck = open_duck
        duck.find(".duck-input").fill_in(with: "Not sent yet")

        check_freshness

        expect_banner(:starts_generation, unsaved: true)
        expect(duck.find(".duck-input").value).to eq("Not sent yet")
        expect(same_load?).to be(true)
      end
    end
  end

  describe "when a newer set exists" do
    it "reloads by itself when nothing is unsaved" do
      travel_to(a_weekday) do
        open_dashboard
        newer_scope = replace_todays_set

        check_freshness

        expect(page).to have_css(%([data-answer-form-draft-scope-value="#{newer_scope}"]))
        expect(same_load?).to be(false)
        expect(page).to have_css("#save-status", text: I18n.t("dashboard.fresh_day.replaced"))
      end
    end

    it "shows the banner and stays when the duck box holds unsent text" do
      travel_to(a_weekday) do
        open_dashboard
        duck = open_duck
        duck.find(".duck-input").fill_in(with: "Not sent yet")
        replace_todays_set

        check_freshness

        expect_banner(:replaced, unsaved: true)
        expect(duck.find(".duck-input").value).to eq("Not sent yet")
        expect(same_load?).to be(true)
      end
    end

    it "shows the banner and keeps unsent duck text when an autosave is refused as stale" do
      travel_to(a_weekday) do
        open_dashboard
        duck = open_duck
        duck.find(".duck-input").fill_in(with: "Not sent yet")
        replace_todays_set

        find(%(textarea[data-field="code_review"])).fill_in(with: "An answer to the replaced set")

        expect_banner(:replaced, unsaved: true)
        expect(duck.find(".duck-input").value).to eq("Not sent yet")
        expect(same_load?).to be(true)
      end
    end

    it "shows the banner and keeps unsent duck text when a submit is refused as stale" do
      travel_to(a_weekday) do
        open_dashboard(ready: true)
        duck = open_duck
        duck.find(".duck-input").fill_in(with: "Not sent yet")
        replace_todays_set

        find("#submit-answers").click

        expect_banner(:replaced, unsaved: true)
        expect(duck.find(".duck-input").value).to eq("Not sent yet")
        expect(same_load?).to be(true)
      end
    end

    it "shows the banner and keeps unsent duck text when Submit's note save is refused as stale" do
      stub_env("LEARNER_NOTES" => "1")
      user.update!(learner_notes_enabled: true)

      travel_to(a_weekday) do
        open_dashboard(ready: true)
        duck = open_duck
        duck.find(".duck-input").fill_in(with: "Not sent yet")
        replace_todays_set
        find("#learner-note textarea").fill_in(with: "A note for the replaced set")

        find("#submit-answers").click

        expect_banner(:replaced, unsaved: true)
        expect(duck.find(".duck-input").value).to eq("Not sent yet")
        expect(same_load?).to be(true)
        expect(user.daily_responses.where.not(submitted_at: nil)).to be_empty
      end
    end

    it "reloads by itself when an autosave is refused as stale and nothing else is unsaved" do
      travel_to(a_weekday) do
        open_dashboard
        newer_scope = replace_todays_set

        find(%(textarea[data-field="code_review"])).fill_in(with: "An answer to the replaced set")

        expect(page).to have_css(%([data-answer-form-draft-scope-value="#{newer_scope}"]))
        expect(same_load?).to be(false)
        expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.stale_reloaded"))
      end
    end

    it "shows the banner and stays when the explanation box holds unsaved text" do
      stub_env("LEARNER_NOTES" => "1")
      user.update!(learner_notes_enabled: true)

      travel_to(a_weekday) do
        submitted_set
        visit_as(user)
        wait_for_js
        watch_this_load
        find("#learner-explanation textarea").fill_in(with: "An explanation not saved yet")
        replace_todays_set

        check_freshness

        expect_banner(:replaced, unsaved: true)
        expect(find("#learner-explanation textarea").value).to eq("An explanation not saved yet")
        expect(same_load?).to be(true)
      end
    end
  end

  describe "paused, with the shown set held and HELD_SET_LOOKUP off" do
    it "says Reload brings the same set forward, and Reload shows it with its saved answers" do
      travel_to(a_weekday) do
        open_dashboard
        find(%(textarea[data-field="code_review"])).fill_in(with: "An answer saved before midnight")
        wait_for { user.daily_responses.first&.answers&.dig("code_review") == "An answer saved before midnight" }
        wait_for_answers_settled
        shown = pass_midnight
        user.update!(paused_generation_at: shown.date.beginning_of_day + 9.hours)

        check_freshness

        expect_banner(:carried_forward, unsaved: false)
        expect(same_load?).to be(true)

        banner.click_button(I18n.t("dashboard.stale_set.reload"))

        expect(page).to have_no_css("#stale-set-banner", visible: true)
        wait_for_js
        expect(same_load?).to be(false)
        expect(page).to have_css(%([data-answer-form-draft-scope-value="#{shown.draft_scope}"]))
        expect(find(%(textarea[data-field="code_review"])).value).to eq("An answer saved before midnight")
        expect(shown.reload.date).to eq(Date.current)
      end
    end

    it "discards a refused edit on Reload and discard changes, so the reloaded page shows the saved answer" do
      travel_to(a_weekday) do
        open_dashboard
        find(%(textarea[data-field="code_review"])).fill_in(with: "An answer saved before midnight")
        wait_for { user.daily_responses.first&.answers&.dig("code_review") == "An answer saved before midnight" }
        wait_for_answers_settled
        shown = pass_midnight
        user.update!(paused_generation_at: shown.date.beginning_of_day + 9.hours)

        find(%(textarea[data-field="code_review"])).fill_in(with: "An edit refused as not current")
        expect_banner(:carried_forward, unsaved: true)
        expect(page.evaluate_script("#{stored_draft_js}?.answers?.code_review")).to eq("An edit refused as not current")

        banner.click_button(discard_label)

        expect(page).to have_no_css("#stale-set-banner", visible: true)
        wait_for_js
        expect(same_load?).to be(false)
        expect(find(%(textarea[data-field="code_review"])).value).to eq("An answer saved before midnight")
        wait_for_answers_settled
        expect(shown.reload.daily_response.answers["code_review"]).to eq("An answer saved before midnight")
      end
    end
  end
end
