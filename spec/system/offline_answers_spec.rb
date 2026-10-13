require "rails_helper"

RSpec.describe "Answers through a lost connection", type: :system do
  let(:user) { create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS) }
  let(:answer) { "An answer written while the connection was down." }
  let(:code_review_field) { %(textarea[data-field="code_review"]) }

  def go_offline(offline = true)
    page.driver.with_playwright_page { |pw| pw.context.set_offline(offline) }
  end

  def break_the_network
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")
  end

  def stored_draft
    raw = page.evaluate_script("localStorage.getItem('code-gym-answer-draft') ?? ''")
    raw.empty? ? nil : JSON.parse(raw)
  end

  def open_dashboard
    visit_with_todays_set(user)
    expect(page).to have_content(/Code Review/i, wait: 10)
    wait_for_js
  end

  def keep_an_unsent_answer
    break_the_network
    find(code_review_field).fill_in(with: answer)
    wait_for_js_condition("JSON.parse(localStorage.getItem('code-gym-answer-draft') || 'null')?.answers?.code_review === #{answer.to_json}")
  end

  def reopen_dashboard
    visit root_path
    expect(page).to have_content(/Code Review/i, wait: 10)
    wait_for_js
  end

  it "keeps typing made offline and saves it once the connection returns" do
    travel_to(a_weekday) do
      open_dashboard
      go_offline

      find(code_review_field).fill_in(with: answer)

      expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.saving_offline"), wait: 10)
      expect(stored_draft["answers"]["code_review"]).to eq(answer)
      expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(true)
      expect(user.daily_responses).to be_empty

      go_offline(false)

      expect(page).to have_no_css("#save-status", visible: true, wait: 10)
      expect(user.daily_responses.sole.answers["code_review"]).to eq(answer)
      wait_for_js_condition("localStorage.getItem('code-gym-answer-draft') === null")
    end
  end

  it "restores an unsent answer when the page is opened again, then saves it" do
    travel_to(a_weekday) do
      open_dashboard
      keep_an_unsent_answer

      reopen_dashboard

      expect(find(code_review_field).value).to eq(answer)
      wait_for_js_condition("localStorage.getItem('code-gym-answer-draft') === null")
      expect(user.daily_responses.sole.answers["code_review"]).to eq(answer)
    end
  end

  it "restores a design comparison's pick and reason into their controls" do
    travel_to(a_weekday) do
      open_dashboard
      break_the_network
      comparison = find(%([data-comparison-answer="design_comparison"]))
      comparison.choose("Piece B")
      comparison.find("textarea[data-comparison-reason]").fill_in(with: "Piece B keeps the retry policy in one place.")
      wait_for_js_condition("JSON.parse(localStorage.getItem('code-gym-answer-draft') || 'null')?.answers?.design_comparison?.includes('retry policy')")

      reopen_dashboard

      comparison = find(%([data-comparison-answer="design_comparison"]))
      expect(comparison.find_field("Piece B", visible: :all)).to be_checked
      expect(comparison.find("textarea[data-comparison-reason]").value).to eq("Piece B keeps the retry policy in one place.")
      wait_for_js_condition("localStorage.getItem('code-gym-answer-draft') === null")
      expect(user.daily_responses.sole.answers["design_comparison"]).to eq("pick:b\nPiece B keeps the retry policy in one place.")
    end
  end

  it "drops a copy written before the set was regenerated" do
    travel_to(a_weekday) do
      open_dashboard
      keep_an_unsent_answer
      user.daily_exercises.sole.update!(generated_at: 1.minute.from_now)

      reopen_dashboard

      expect(find(code_review_field).value).not_to eq(answer)
      expect(stored_draft).to be_nil
    end
  end

  it "drops a copy written before Start over" do
    travel_to(a_weekday) do
      open_dashboard
      find(code_review_field).fill_in(with: "An answer that reached the server first.")
      wait_for_js_condition("localStorage.getItem('code-gym-answer-draft') === null && document.querySelector('.section-status[data-status-for=\"code_review\"]')?.textContent.trim() !== ''")
      keep_an_unsent_answer
      user.daily_responses.sole.destroy

      reopen_dashboard

      expect(find(code_review_field).value).not_to eq(answer)
      expect(stored_draft).to be_nil
    end
  end

  it "drops a copy when the server's draft changed after it was taken" do
    travel_to(a_weekday) do
      open_dashboard
      keep_an_unsent_answer
      exercise = user.daily_exercises.sole
      user.daily_responses.create!(daily_exercise: exercise, date: exercise.date,
                                   answers: { "code_review" => "Text saved from another device." })

      reopen_dashboard

      expect(find(code_review_field).value).to eq("Text saved from another device.")
      expect(stored_draft).to be_nil
    end
  end

  it "does not retry a save the server refused" do
    travel_to(a_weekday) do
      open_dashboard
      page.execute_script(<<~JS)
        window.saveAttempts = 0
        window.fetch = () => {
          window.saveAttempts += 1
          return Promise.resolve(new Response(JSON.stringify({ status: "error", error: "The server said no." }),
                                              { status: 422, headers: { "Content-Type": "application/json" } }))
        }
      JS

      find(code_review_field).fill_in(with: answer)
      expect(page).to have_css("#save-status", text: "The server said no.", wait: 10)
      page.execute_script("window.dispatchEvent(new Event('online'))")

      expect(page.evaluate_script("window.saveAttempts")).to eq(1)
      expect(page.evaluate_script("window.CodeGymSaveStatus.pending()")).to be(false)
    end
  end

  it "clears the copy once the server confirms the save" do
    travel_to(a_weekday) do
      open_dashboard

      find(code_review_field).fill_in(with: answer)

      wait_for_js_condition("localStorage.getItem('code-gym-answer-draft') === null && !window.CodeGymSaveStatus.pending()")
      expect(user.daily_responses.sole.answers["code_review"]).to eq(answer)
    end
  end

  it "clears every copy on logout" do
    travel_to(a_weekday) do
      open_dashboard
      keep_an_unsent_answer

      visit account_path
      click_button I18n.t("accounts.show.log_out")

      expect(page).to have_current_path(login_path, wait: 10)
      wait_for_js_condition("localStorage.getItem('code-gym-answer-draft') === null")
    end
  end

  it "keeps saying the answers were not submitted when a retry already waiting fails again" do
    travel_to(a_weekday) do
      open_dashboard
      fill_in_answer("code_review", answer)
      rate_section("code_review")
      expect_ready_to_submit
      go_offline
      find(code_review_field).fill_in(with: "#{answer} One more line typed offline.")
      expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.saving_offline"), wait: 10)

      click_button I18n.t("dashboard.exercise.submit")
      expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.submit_offline"), wait: 10)
      page.execute_script("window.dispatchEvent(new Event('online'))")
      sleep 0.5

      expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.submit_offline"))
    end
  end

  it "keeps the answers and Submit when submitting offline, and submits once back online" do
    travel_to(a_weekday) do
      open_dashboard
      fill_in_answer("code_review", answer)
      rate_section("code_review")
      expect_ready_to_submit
      go_offline

      click_button I18n.t("dashboard.exercise.submit")

      expect(page).to have_css("#save-status", text: I18n.t("dashboard.exercise.submit_offline"), wait: 10)
      expect(page).to have_button(I18n.t("dashboard.exercise.submit"), disabled: false)
      expect(user.daily_responses.sole).not_to be_submitted

      go_offline(false)
      expect(page).to have_no_css("#save-status", visible: true, wait: 10)
      click_button I18n.t("dashboard.exercise.submit")

      expect(page).to have_no_css("#gym-form", wait: 15)
      expect(user.daily_responses.sole).to be_submitted
      expect(stored_draft).to be_nil
    end
  end
end
