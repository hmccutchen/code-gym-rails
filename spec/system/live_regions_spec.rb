require "rails_helper"

# Content arriving after a request must land in a live region, or a screen reader never reads it.
RSpec.describe "Live regions", type: :system, with_csrf: true do
  let(:user) { create_fake_provider_user }

  def reviewed_day
    exercise = DailyExercise.create!(
      user: user, date: Date.current - 3, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "What is wrong here?", "snippet" => "orders.each { |o| o.customer }" } }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current - 3,
      answers: { "code_review" => "It loads the customer once per order." },
      submitted_at: Time.current,
      ai_review: { "code_review" => { "rating" => "solid", "missed" => [ "Eager loading" ] } }
    )
  end

  def live_text(selector)
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll(#{selector.to_json})]
        .filter(el => el.closest('[aria-live], [role="alert"], [role="status"]'))
        .map(el => el.textContent).join(" ")
    JS
  end

  it "announces that a review's different explanation was added" do
    reviewed_day
    visit_as(user)
    visit history_path
    click_button "Explain this differently", match: :first

    expect(page).to have_css(".alternate-status", text: "A different explanation was added above", wait: 10)
    expect(page).to have_css(".alternate-item", text: FakeService::EXPLAIN_DIFFERENTLY_TEXT.first(30))
  end

  it "adds a follow-up answer inside a live region" do
    reviewed_day
    visit_as(user)
    visit history_path
    find(".follow-up-input", match: :first).fill_in(with: "Why eager loading?")
    click_button "Ask", match: :first

    expect(page).to have_css(".follow-up-thread[aria-live='polite'] .follow-up-turn", text: FakeService::FOLLOW_UP_ANSWER_TEXT.first(30), wait: 10)
  end

  it "announces a failed save assertively" do
    visit_as(user)
    visit learn_path
    page.execute_script(%(window.CodeGymSaveStatus.save("PATCH", "/no-such-endpoint", {}, "probe")))

    expect(page).to have_css("#save-status", text: /couldn't save/i, wait: 5)
    expect(page.find("#save-status-announcer", visible: :all)[:role]).to eq("alert")
    expect(live_text("#save-status-announcer")).to match(/couldn't save/i)
  end
end
