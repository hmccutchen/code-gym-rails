require "rails_helper"

# with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "A reviewed section's different explanation", type: :system, with_csrf: true do
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
      ai_review: { "code_review" => { "rating" => "solid", "missed" => [ "A quick note" ] } }
    )
  end

  def open_history
    reviewed_day
    visit_as(user)
    visit history_path
  end

  it "underlines a glossary term in a new explanation, and its definition opens" do
    open_history

    click_button "Explain this differently", match: :first

    term = find(".alternate-item .gloss-term", text: "service object")
    term.click
    expect(term[:class]).to include("gloss-open")
  end

  it "shows an explanation from a server that sends no HTML as plain text, since the call was already paid for" do
    open_history
    box = first(".alternates")
    stub_fetch(box["data-review-alternates-url-value"], <<~JS)
      Promise.resolve(new Response(JSON.stringify({ alternate: "<b>Bold</b> service object", remaining: 1 }),
        { status: 200, headers: { "Content-Type": "application/json" } }))
    JS

    click_button "Explain this differently", match: :first

    expect(box.find(".alternate-item")).to have_text("<b>Bold</b> service object")
    expect(box).to have_no_css(".alternate-item b, .alternate-item .gloss-term")
  end
end
